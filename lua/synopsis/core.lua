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
local store = require 'synopsis.store'
local prompt = require 'synopsis.prompt'
local llm = require 'synopsis.llm'

local Core = {}
Core.__index = Core

local M = {}

---opts: { llm, background, delay_ms, max_bytes, max_concurrent, exclude, render }
function M.new(opts)
  local self = setmetatable({ opts = opts, pending = {}, queue = {}, active = 0 }, Core)
  self.timer = assert(vim.uv.new_timer())
  self.exclude = vim.tbl_map(function(g) return vim.glob.to_lpeg(g) end, opts.exclude or {})
  return self
end

local function read_file(path)
  local f = io.open(path, 'rb')
  if not f then return nil end
  local text = f:read '*a'
  f:close()
  return text
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

function Core:render(path, kind, text)
  if path == self.current then self.opts.render(path, { kind = kind, text = text }) end
end

---Why `path` must not be sent, or nil if it may be. Returns the file text when it may.
function Core:check(path, rel)
  local stat = vim.uv.fs_stat(path)
  if not stat or stat.type ~= 'file' then return 'not a file' end
  local base = vim.fs.basename(path)
  for _, pat in ipairs(self.exclude) do
    if pat:match(base) or pat:match(rel) then return 'excluded by the exclude setting' end
  end
  if stat.size > self.opts.max_bytes then
    return string.format('too large to summarize (%d KB; the limit is %d KB)', math.ceil(stat.size / 1024), math.floor(self.opts.max_bytes / 1024))
  end
  local text = read_file(path)
  if not text then return 'could not be read' end
  if text:sub(1, 8192):find('\0', 1, true) then return 'binary file' end
  return nil, text
end

---Called whenever the picker previews `path`.
function Core:preview(path)
  self.timer:stop()
  self.current = path
  local root, rel = locate(path)
  local reason, text = self:check(path, rel)
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
  if status == 'stale' then
    self:render(path, 'outdated', entry.summary)
  else
    self:render(path, 'waiting')
  end
  self.timer:start(self.opts.delay_ms, 0, vim.schedule_wrap(function()
    if self.current == path and not self.pending[path] then self:enqueue(job) end
  end))
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
    local messages = prompt.build { root = job.root, relpath = job.rel, text = job.text, background = self.opts.background }
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
    end)
  end
end

return M
