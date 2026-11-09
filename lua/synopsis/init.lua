-- synopsis: a short LLM-written summary of each file, shown in a pane above Telescope's results,
-- and :SynopsisAsk, which answers questions about the repo. Use the pane by giving a picker
-- `layout_strategy = 'synopsis'`.
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
    -- Let the provider reuse the start of the prompt that a repo's files share (README, file
    -- list). 'auto': OpenAI's cache points when url is api.openai.com; 'openai': always; false:
    -- never. prompt_cache_key sends a hash of the repo root; false if your server rejects it.
    cache = 'auto',
    prompt_cache_key = true,
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
  -- Keys in the picker's prompt; false for none. scroll_* move the synopsis half a page (Telescope
  -- uses <C-u>/<C-d> for the preview and <PageUp>/<PageDown> for the results); allow / deny
  -- answer whether this repo's files may be sent. Ctrl keys rather than Alt keys, because many
  -- macOS terminals send Option as a character, not as Alt.
  -- ask opens the :SynopsisAsk chat about the selected file, or moves to it when it is open.
  keymaps = { scroll_up = '<C-y>', scroll_down = '<C-e>', allow = '<C-a>', deny = '<C-o>', ask = '<C-Space>' },
  -- :SynopsisAsk. The model gets a map of the repo's files (leading comments and definition
  -- names, built without a model) and tools to search and read the code, for up to max_rounds
  -- turns of tool calls. Files past max_map_chars are listed by path only. render: draw the
  -- chat's markdown and LaTeX with markview.nvim and snacks.nvim when they are installed.
  -- preview: a pane on the right showing the cited lines, on screens at least
  -- preview_min_columns wide. Each repo's conversation is kept for the editor session. Opened
  -- with Ctrl-Space on a screen at least side_min_columns wide, the chat sits beside the picker,
  -- which stays open, and shows cited lines in Telescope's preview.
  -- Keys, all in the input panel, where the typing cursor stays: open (<CR>) sends the question,
  -- or with nothing typed opens the selected link; next_citation / prev_citation move the
  -- selected link; open_split / open_vsplit / open_tab open it as Telescope does; picker goes
  -- back to the picker's prompt, when beside one; close and locations in Normal mode; false
  -- for none.
  ask = {
    max_rounds = 10,
    max_map_chars = 150000,
    render = true,
    preview = true,
    preview_min_columns = 120,
    side_min_columns = 180,
    keymaps = {
      close = { 'q', '<Esc>' }, open = '<CR>', locations = 'gl', new_chat = '<C-n>',
      next_citation = '<Tab>', prev_citation = '<S-Tab>', picker = '<C-Space>',
      open_split = '<C-x>', open_vsplit = '<C-v>', open_tab = '<C-t>', -- as in Telescope
      scroll_preview_down = '<C-d>', scroll_preview_up = '<C-u>', -- as in Telescope
    },
  },
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
    vim.notify('synopsis: files from ' .. repo() .. ' may be sent for synopses')
  end, { desc = "Allow this buffer's repo to be sent for synopses" })
  vim.api.nvim_create_user_command('SynopsisDeny', function()
    require('synopsis.consent').set(repo(), 'deny')
    vim.notify('synopsis: synopses are off for ' .. repo())
  end, { desc = "Never send this buffer's repo for synopses" })

  vim.api.nvim_create_user_command('SynopsisAsk', function(o)
    local root = vim.fs.normalize(vim.fn.resolve(repo()))
    require('synopsis.answer').open { root = root, question = o.args ~= '' and o.args or nil, config = M.config }
  end, { nargs = '*', desc = "Open a chat about this buffer's repo, asking the question if one is given" })

  vim.api.nvim_create_user_command('SynopsisClear', function()
    local store = require 'synopsis.store'
    local root = vim.fs.root(0, '.git') or vim.fn.getcwd()
    local dir = vim.fs.dirname(store.entry_path(root, 'x'))
    vim.fn.delete(dir, 'rf')
    vim.notify('synopsis: cleared the synopses for ' .. root)
  end, { desc = "Delete the cached synopses for this buffer's repo" })
end

return M
