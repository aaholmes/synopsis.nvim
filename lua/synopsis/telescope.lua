-- The summary pane in Telescope. A layout strategy, `synopsis`, lays the picker out as
-- `horizontal` does, then shortens the results window from the top to leave room for the pane,
-- and records that space on the picker. Each `User TelescopePreviewerLoaded` event (one per
-- file previewed) opens or moves the pane there and passes the file to the core. dock() narrows
-- the picker to leave a column on its right for the :SynopsisAsk chat, and keeps the picker open
-- when the focus leaves its prompt; undock() undoes both.
local M = {}

local function layout_strategies() return require 'telescope.pickers.layout_strategies' end

---Lines of text for the pane, given the rows the results had before the pane took some:
---`height` below 1 is a fraction of them, otherwise a line count. The results keep at least 3.
local function pane_height(height, rows)
  local h = height < 1 and math.floor(height * (rows - 2)) or height
  return math.max(1, math.min(h, rows - 2 - 3))
end

---The outer box of a Telescope layout, borders included, in 0-based screen cells. Telescope's
---positions are the 1-based text area, with borders one cell outside it.
local function edges(layout)
  local l, r, t, b = math.huge, -math.huge, math.huge, -math.huge
  for _, k in ipairs { 'prompt', 'results', 'preview' } do
    local e = layout[k]
    if e then
      l, r = math.min(l, e.col - 2), math.max(r, e.col + e.width - 1)
      t, b = math.min(t, e.line - 2), math.max(b, e.line + e.height - 1)
    end
  end
  return l, r, t, b
end

---Register the `synopsis` layout strategy, giving the pane `height` (a fraction or lines).
---When the chat is docked (picker._synopsis_side), the layout is narrowed from the right by
---about 38% of its width, keeping its left edge; picker._synopsis_dock records the freed box.
function M.register(height)
  local ls = layout_strategies()
  ls._configurations.synopsis = ls._configurations.horizontal
  ls.synopsis = function(picker, max_columns, max_lines, layout_config)
    local layout = ls.horizontal(picker, max_columns, max_lines, layout_config)
    picker._synopsis_dock = nil
    if picker._synopsis_side then
      local left, right, top, bottom = edges(layout)
      local width = right - left + 1
      local side = math.max(50, math.min(100, math.floor(width * 0.38)))
      -- Telescope's defaults set width under `horizontal`, which wins over a top-level width.
      local lc = vim.tbl_extend('force', layout_config or {}, { width = width - side })
      lc.horizontal = vim.tbl_extend('force', lc.horizontal or {}, { width = width - side })
      layout = ls.horizontal(picker, max_columns, max_lines, lc)
      local l2, r2 = edges(layout)
      for _, k in ipairs { 'prompt', 'results', 'preview' } do
        if layout[k] then layout[k].col = layout[k].col - (l2 - left) end
      end
      local col = r2 - (l2 - left) + 2
      picker._synopsis_dock = { row = top, col = col, width = right - col + 1, height = bottom - top + 1 }
    end
    local r = layout.results
    -- Telescope's positions are the text area; borders are drawn one cell outside it. The pane's
    -- border takes the results border's old top row, so the space freed is height + 2 rows.
    local h = pane_height(height, r.height)
    picker._synopsis = { row = r.line - 2, col = r.col - 2, width = r.width, height = h }
    r.line = r.line + h + 2
    r.height = r.height - h - 2
    return layout
  end
end

local pane = { win = nil, buf = nil, picker = nil }

local function close_pane()
  if pane.win and vim.api.nvim_win_is_valid(pane.win) then vim.api.nvim_win_close(pane.win, true) end
  pane.win, pane.picker = nil, nil
end

local function win_config(g)
  return {
    relative = 'editor', row = g.row, col = g.col, width = g.width, height = g.height,
    -- Focusable so the mouse wheel scrolls it; the prompt keeps the focus.
    style = 'minimal', border = 'rounded', focusable = true, zindex = 50,
    title = ' Synopsis ', title_pos = 'center',
  }
end

local function open_pane(picker)
  if not (pane.buf and vim.api.nvim_buf_is_valid(pane.buf)) then
    pane.buf = vim.api.nvim_create_buf(false, true)
    vim.bo[pane.buf].bufhidden = 'hide'
    vim.b[pane.buf].synopsis = true
  end
  if pane.win and vim.api.nvim_win_is_valid(pane.win) then
    vim.api.nvim_win_set_config(pane.win, win_config(picker._synopsis))
  else
    pane.win = vim.api.nvim_open_win(pane.buf, false, win_config(picker._synopsis))
    -- The text is wrapped to the pane's width when it is laid out (see render.lua).
    vim.wo[pane.win].wrap = false
    vim.wo[pane.win].winhighlight = 'Normal:TelescopeResultsNormal,FloatBorder:TelescopeResultsBorder,FloatTitle:TelescopeResultsTitle'
  end
  pane.picker = picker
end

local function current_picker()
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(b) and vim.bo[b].filetype == 'TelescopePrompt' then
      local picker = require('telescope.actions.state').get_current_picker(b)
      if picker then return picker, b end
    end
  end
end

local ns = vim.api.nvim_create_namespace 'synopsis.pane'

---Show `view` in the pane, laid out for its current width. The view is kept so a resize can
---lay it out again.
function M.render(_, view)
  pane.view = view
  if not (pane.buf and vim.api.nvim_buf_is_valid(pane.buf)) then return end
  local width = (pane.win and vim.api.nvim_win_is_valid(pane.win)) and vim.api.nvim_win_get_width(pane.win) or 40
  local r = require('synopsis.render').layout(view, width, { keymaps = M.keymaps })
  vim.bo[pane.buf].modifiable = true
  vim.api.nvim_buf_set_lines(pane.buf, 0, -1, false, r.lines)
  vim.bo[pane.buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(pane.buf, ns, 0, -1)
  for _, m in ipairs(r.marks) do
    vim.api.nvim_buf_set_extmark(pane.buf, ns, m.row, m.col, { end_col = m.end_col, hl_group = m.hl })
  end
  if pane.win and vim.api.nvim_win_is_valid(pane.win) then vim.api.nvim_win_set_cursor(pane.win, { 1, 0 }) end
end

---Scroll the pane half a page down (dir = 1) or up (dir = -1), as Telescope scrolls the preview.
function M.scroll(dir)
  if not (pane.win and vim.api.nvim_win_is_valid(pane.win)) then return end
  local n = math.max(1, math.floor(vim.api.nvim_win_get_height(pane.win) / 2))
  vim.api.nvim_win_call(pane.win, function() vim.cmd('normal! ' .. n .. vim.keycode(dir > 0 and '<C-e>' or '<C-y>')) end)
end

---Lay the picker out again (Telescope moves its windows in place), and the pane with it.
local function relayout(picker)
  picker:full_layout_update()
  if pane.picker == picker and picker._synopsis then
    open_pane(picker)
    if pane.view then M.render(nil, pane.view) end
  end
end

---Make room for the chat on the picker's right, and keep the picker open while the focus is in
---the chat: Telescope closes a picker when its prompt loses the focus, with one BufLeave
---autocmd in its PickerInsert group. Returns the freed box { row, col, width, height }.
function M.dock(picker, prompt)
  vim.api.nvim_clear_autocmds { group = 'PickerInsert', event = 'BufLeave', buffer = prompt }
  picker._synopsis_side = true
  relayout(picker)
  return picker._synopsis_dock
end

---Give the picker its full width back, and restore Telescope's close-on-leave as it sets it up.
function M.undock(picker, prompt)
  picker._synopsis_side = nil
  if not vim.api.nvim_buf_is_valid(prompt) then return end
  relayout(picker)
  vim.api.nvim_create_autocmd('BufLeave', {
    buffer = prompt, group = 'PickerInsert', nested = true, once = true,
    callback = function() require('telescope.pickers').on_close_prompt(prompt) end,
  })
end

---Open the :SynopsisAsk chat about the picker's selected file. On a screen at least
---ask.side_min_columns wide, the chat opens beside the picker, which stays open; otherwise the
---picker closes, and closing the chat reopens it where it was.
function M.ask_about(prompt, picker)
  local entry = require('telescope.actions.state').get_selected_entry()
  if not entry then return end
  local name = entry.path or entry.filename or (type(entry.value) == 'string' and entry.value) or nil
  if not name then return end
  if not name:match '^/' then name = vim.fs.joinpath(picker.cwd or vim.fn.getcwd(), name) end
  name = vim.fs.normalize(vim.fn.resolve(name))
  local root = vim.fs.root(name, '.git') or vim.fs.dirname(name)
  local rel = vim.fs.relpath(root, name) or vim.fs.basename(name)
  local config = require('synopsis').config
  local answer = require 'synopsis.answer'
  local about = { path = rel, line = entry.lnum }
  if picker._synopsis and vim.o.columns >= ((config.ask or {}).side_min_columns or 180) then
    local s = answer.current
    if s and not s.closed and s.dock and s.dock.prompt == prompt and s.root == root then return answer.focus(about) end
    return answer.open { root = root, config = config, about = about, dock = { prompt = prompt, picker = picker } }
  end
  require('telescope.actions').close(prompt)
  vim.schedule(function()
    require('synopsis.answer').open {
      root = root, config = config, about = about,
      on_close = function() require('telescope.builtin').resume() end,
    }
  end)
end

---Hook the pane into Telescope for `core`. `keymaps` ({ scroll_up, scroll_down, allow, deny, ask },
---any of them false to skip it) are mapped in the prompt buffer of each picker with the pane.
function M.attach(core, keymaps)
  M.keymaps = keymaps or {}
  local group = vim.api.nvim_create_augroup('synopsis', { clear = true })
  -- Keys and clean-up are set up when each prompt buffer is created, so they do not depend on a
  -- preview being shown (a picker without one, or a resumed picker whose preview is cached).
  vim.api.nvim_create_autocmd('FileType', {
    group = group,
    pattern = 'TelescopePrompt',
    callback = function(ev)
      local prompt = ev.buf
      vim.schedule(function()
        if not vim.api.nvim_buf_is_valid(prompt) then return end
        local ok, picker = pcall(require('telescope.actions.state').get_current_picker, prompt)
        if not (ok and picker and picker.layout_strategy == 'synopsis') then return end
        local actions = {
          scroll_down = { function() M.scroll(1) end, 'scroll the synopsis down' },
          scroll_up = { function() M.scroll(-1) end, 'scroll the synopsis up' },
          allow = { function() core:decide 'allow' end, "send this repo's files for synopses" },
          deny = { function() core:decide 'deny' end, 'turn synopses off for this repo' },
          ask = { function() M.ask_about(prompt, picker) end, 'ask about this file' },
        }
        for name, action in pairs(actions) do
          local lhs = M.keymaps[name]
          if lhs then vim.keymap.set({ 'i', 'n' }, lhs, action[1], { buffer = prompt, desc = 'synopsis: ' .. action[2] }) end
        end
        vim.api.nvim_create_autocmd({ 'BufWipeout', 'BufUnload' }, {
          group = group, buffer = prompt, once = true,
          callback = function()
            core:leave()
            close_pane()
            local answer = package.loaded['synopsis.answer']
            local s = answer and answer.current
            if s and not s.closed and s.dock and s.dock.prompt == prompt then answer.close { picker_gone = true } end
          end,
        })
        vim.api.nvim_create_autocmd('VimResized', {
          group = group, buffer = prompt,
          -- Telescope recomputes the layout in its own VimResized handler; move the pane after it.
          callback = function()
            vim.schedule(function()
              if pane.picker == picker then
                open_pane(picker)
                if pane.view then M.render(nil, pane.view) end
              end
              local answer = package.loaded['synopsis.answer']
              if answer and answer.current and answer.current.dock and answer.current.dock.prompt == prompt then
                answer.relayout()
              end
            end)
          end,
        })
      end)
    end,
  })
  vim.api.nvim_create_autocmd('User', {
    group = group,
    pattern = 'TelescopePreviewerLoaded',
    callback = function(ev)
      local picker = current_picker()
      if not (picker and picker._synopsis and picker.layout_strategy == 'synopsis') then return end
      open_pane(picker)
      local name = ev.data and ev.data.bufname
      if not name or name == '' then return core:leave() end
      if not name:match '^/' then name = vim.fs.joinpath(picker.cwd or vim.fn.getcwd(), name) end
      core:preview(vim.fs.normalize(name))
    end,
  })
end

return M
