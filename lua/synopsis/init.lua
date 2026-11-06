-- synopsis: a short LLM-written summary of each file, shown in a pane above Telescope's results.
-- Use it by giving a picker `layout_strategy = 'synopsis'`.
local M = {}

local defaults = {
  -- Any OpenAI-compatible chat endpoint. api_key_env = false sends no key (a local server).
  -- GPT-6 Luna with reasoning off is butwhy's default: accurate, about $0.10 / $0.50 per
  -- million tokens in / out.
  llm = {
    url = 'https://api.openai.com',
    chat_path = '/v1/chat/completions',
    model = 'gpt-6-luna',
    api_key_env = 'OPENAI_API_KEY',
    params = { reasoning_effort = 'none' },
    timeout_ms = 30000,
  },
  -- Reader background, so summaries are pitched at your level. Shared with butwhy.
  background = '~/.config/butwhy/background.md',
  -- 'ask': before the first file of a repo is sent, the pane asks whether that repo may be sent
  -- (answered with the allow / deny keys or :SynopsisAllow / :SynopsisDeny, and remembered).
  -- 'always': send without asking, e.g. for a local model server.
  consent = 'ask',
  -- How long a file must stay previewed before its summary is requested.
  delay_ms = 1000,
  -- Files larger than this, binary files and files matching `exclude` are never sent.
  max_bytes = 100 * 1024,
  exclude = { '.env', '.env.*', '*.pem', '*.key', '*secret*', '*.lock', '*-lock.json' },
  max_concurrent = 3,
  -- Height of the summary pane: below 1, a fraction of the left column's rows (the results get
  -- the rest); otherwise a number of lines.
  height = 0.6,
  -- Keys in the picker's prompt; false for none. scroll_* move the summary half a page (Telescope
  -- uses <C-u>/<C-d> for the preview and <PageUp>/<PageDown> for the results); allow / deny
  -- answer whether this repo's files may be sent.
  keymaps = { scroll_up = '<M-u>', scroll_down = '<M-d>', allow = '<M-y>', deny = '<M-n>' },
}

M.config = vim.deepcopy(defaults)

function M.setup(opts)
  M.config = vim.tbl_deep_extend('force', vim.deepcopy(defaults), opts or {})
  M.config.background = vim.fs.normalize(M.config.background)
  local tele = require 'synopsis.telescope'
  M.core = require('synopsis.core').new(vim.tbl_extend('force', M.config, { render = tele.render }))
  tele.register(M.config.height)
  tele.attach(M.core, M.config.keymaps)

  local function repo() return vim.fs.root(0, '.git') or vim.fn.getcwd() end
  vim.api.nvim_create_user_command('SynopsisAllow', function()
    require('synopsis.consent').set(repo(), 'allow')
    vim.notify('synopsis: files from ' .. repo() .. ' may be sent for summaries')
  end, { desc = "Allow this buffer's repo to be sent for summaries" })
  vim.api.nvim_create_user_command('SynopsisDeny', function()
    require('synopsis.consent').set(repo(), 'deny')
    vim.notify('synopsis: summaries are off for ' .. repo())
  end, { desc = "Never send this buffer's repo for summaries" })

  vim.api.nvim_create_user_command('SynopsisClear', function()
    local store = require 'synopsis.store'
    local root = vim.fs.root(0, '.git') or vim.fn.getcwd()
    local dir = vim.fs.dirname(store.entry_path(root, 'x'))
    vim.fn.delete(dir, 'rf')
    vim.notify('synopsis: cleared the summaries for ' .. root)
  end, { desc = "Delete the cached summaries for this buffer's repo" })
end

return M
