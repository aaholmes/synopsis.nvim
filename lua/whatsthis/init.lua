-- whatsthis: a short LLM-written summary of each file, shown in a pane above Telescope's results.
-- Use it by giving a picker `layout_strategy = 'whatsthis'`.
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
  -- How long a file must stay previewed before its summary is requested.
  delay_ms = 1000,
  -- Files larger than this, binary files and files matching `exclude` are never sent.
  max_bytes = 100 * 1024,
  exclude = { '.env', '.env.*', '*.pem', '*.key', '*secret*', '*.lock', '*-lock.json' },
  max_concurrent = 3,
  -- Height of the summary pane: below 1, a fraction of the left column's rows (the results get
  -- the rest); otherwise a number of lines.
  height = 0.6,
  -- Keys, in the picker's prompt, that scroll the summary half a page; false for none. Telescope
  -- uses <C-u>/<C-d> for the preview and <PageUp>/<PageDown> for the results.
  keymaps = { scroll_up = '<M-u>', scroll_down = '<M-d>' },
}

M.config = vim.deepcopy(defaults)

function M.setup(opts)
  M.config = vim.tbl_deep_extend('force', vim.deepcopy(defaults), opts or {})
  M.config.background = vim.fs.normalize(M.config.background)
  local tele = require 'whatsthis.telescope'
  M.core = require('whatsthis.core').new(vim.tbl_extend('force', M.config, { render = tele.render }))
  tele.register(M.config.height)
  tele.attach(M.core, M.config.keymaps)

  vim.api.nvim_create_user_command('WhatsthisClear', function()
    local store = require 'whatsthis.store'
    local root = vim.fs.root(0, '.git') or vim.fn.getcwd()
    local dir = vim.fs.dirname(store.entry_path(root, 'x'))
    vim.fn.delete(dir, 'rf')
    vim.notify('whatsthis: cleared the summaries for ' .. root)
  end, { desc = "Delete the cached summaries for this buffer's repo" })
end

return M
