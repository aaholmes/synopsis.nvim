-- Decides what to show for the previewed file and when to ask for a summary. A cached summary
-- is shown immediately; a missing or outdated one is requested once the file has been
-- previewed for `delay_ms` without moving on. Picker-independent: it reports what to show
-- through `render(path, view)`, where view.kind is one of
--   summary   the current summary (view.text)
--   outdated  a summary of an earlier version of the file or prompt (view.text); a new one follows
--   waiting   no summary yet; one is requested if the file stays previewed
--   pending   a request is in flight
--   skipped   never sent (view.text gives the reason)
--   error     the request failed (view.text)
--   ask       the user has not said whether this repo (view.text) may be sent to view.host
--   off       the user said no for this repo; view.text is an older summary, if any
local store = require 'synopsis.store'
local consent = require 'synopsis.consent'
local prompt = require 'synopsis.prompt'
local llm = require 'synopsis.llm'
local files = require 'synopsis.files'

local Core = {}
Core.__index = Core

local M = {}

---opts: { llm, background, delay_ms, max_bytes, max_concurrent, exclude, render, consent }.
---consent = 'always' sends without asking; anything else asks once for each repo.
function M.new(opts)
  local self = setmetatable({ opts = opts, pending = {}, queue = {}, active = 0 }, Core)
  self.timer = assert(vim.uv.new_timer())
  return self
end

---The repo root and path relative to it: the nearest directory holding .git, else the
---current directory (or the file's own directory if it lies outside that).
local function locate(path)
  local root = vim.fs.root(path, '.git') or vim.fn.getcwd()
  local rel = vim.fs.relpath(root, path)
  if not rel then
    root = vim.fs.dirname(path)
    rel = vim.fs.basename(path)
  end
  return root, rel
end

function Core:render(path, kind, text, host)
  if path == self.current then self.opts.render(path, { kind = kind, text = text, host = host }) end
end

---Why `path` must not be sent, or nil if it may be. Returns the file text when it may.
function Core:check(root, rel)
  return files.skip_reason(root, rel, self.opts)
end

---Called whenever the picker previews `path`.
function Core:preview(path)
  self.timer:stop()
  self.current = path
  local root, rel = locate(path)
  self.current_root = root
  local reason, text = self:check(root, rel)
  if reason then return self:render(path, 'skipped', reason) end

  local job = {
    path = path, root = root, rel = rel, text = text,
    content_hash = vim.fn.sha256(text),
    prompt_hash = prompt.hash(self.opts.background, self.opts.llm.model),
  }
  local entry = store.read(root, rel)
  local status = store.status(entry, job.content_hash, job.prompt_hash)
  if status == 'fresh' then return self:render(path, 'summary', entry.summary) end
  if self.pending[path] then return self:render(path, 'pending', entry and entry.summary) end
  local decision = self.opts.consent == 'always' and 'allow' or consent.get(root)
  if decision == 'deny' then return self:render(path, 'off', entry and entry.summary) end
  if decision ~= 'allow' then
    return self:render(path, 'ask', root, (self.opts.llm.url or ''):match '^%a+://([^/:]+)' or self.opts.llm.url)
  end
  if status == 'stale' then
    self:render(path, 'outdated', entry.summary)
  else
    self:render(path, 'waiting')
  end
  self.timer:start(self.opts.delay_ms, 0, vim.schedule_wrap(function()
    if self.current == path and not self.pending[path] then self:enqueue(job) end
  end))
end

---Record the user's answer ('allow' or 'deny') for the repo of the previewed file, then show
---that file again under the new decision.
function Core:decide(choice)
  if not self.current then return end
  consent.set(self.current_root, choice)
  self:preview(self.current)
end

---Called when the picker closes or previews something that is not a file.
function Core:leave()
  self.timer:stop()
  self.current = nil
end

function Core:enqueue(job)
  self.pending[job.path] = true
  table.insert(self.queue, job)
  self:render(job.path, 'pending')
  self:pump()
end

function Core:pump()
  while self.active < self.opts.max_concurrent and #self.queue > 0 do
    local job = table.remove(self.queue, 1)
    self.active = self.active + 1
    -- Files of one repo share the start of their prompt (background, README, file list), which
    -- the provider can serve from its cache.
    local built, shared = prompt.build { root = job.root, relpath = job.rel, text = job.text, background = self.opts.background }
    local messages, extra = llm.prepare(self.opts.llm, built, shared, store.root_key(job.root))
    llm.request(self.opts.llm, messages, function(err, summary)
      self.active = self.active - 1
      self.pending[job.path] = nil
      if err then
        self:render(job.path, 'error', err)
      else
        store.write(job.root, job.rel, {
          path = job.rel, content_hash = job.content_hash, prompt_hash = job.prompt_hash,
          model = self.opts.llm.model, summary = summary, created = os.time(),
        })
        self:render(job.path, 'summary', summary)
      end
      self:pump()
    end, extra)
  end
end

return M
