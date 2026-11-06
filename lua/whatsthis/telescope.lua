-- The summary pane in Telescope. A layout strategy, `whatsthis`, lays the picker out as
-- `horizontal` does, then shortens the results window from the top to leave room for the pane,
-- and records that space on the picker. Each `User TelescopePreviewerLoaded` event (one per
-- file previewed) opens or moves the pane there and passes the file to the core.
local M = {}

local function layout_strategies() return require 'telescope.pickers.layout_strategies' end

---Lines of text for the pane, given the rows the results had before the pane took some:
---`height` below 1 is a fraction of them, otherwise a line count. The results keep at least 3.
local function pane_height(height, rows)
  local h = height < 1 and math.floor(height * (rows - 2)) or height
  return math.max(1, math.min(h, rows - 2 - 3))
end

---Register the `whatsthis` layout strategy, giving the pane `height` (a fraction or lines).
function M.register(height)
  local ls = layout_strategies()
  ls._configurations.whatsthis = ls._configurations.horizontal
  ls.whatsthis = function(picker, max_columns, max_lines, layout_config)
    local layout = ls.horizontal(picker, max_columns, max_lines, layout_config)
    local r = layout.results
    -- Telescope's positions are the text area; borders are drawn one cell outside it. The pane's
    -- border takes the results border's old top row, so the space freed is height + 2 rows.
    local h = pane_height(height, r.height)
    picker._whatsthis = { row = r.line - 2, col = r.col - 2, width = r.width, height = h }
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
    title = ' Summary ', title_pos = 'center',
  }
end

local function open_pane(picker)
  if not (pane.buf and vim.api.nvim_buf_is_valid(pane.buf)) then
    pane.buf = vim.api.nvim_create_buf(false, true)
    vim.bo[pane.buf].bufhidden = 'hide'
    vim.b[pane.buf].whatsthis = true
  end
  if pane.win and vim.api.nvim_win_is_valid(pane.win) then
    vim.api.nvim_win_set_config(pane.win, win_config(picker._whatsthis))
  else
    pane.win = vim.api.nvim_open_win(pane.buf, false, win_config(picker._whatsthis))
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

local ns = vim.api.nvim_create_namespace 'whatsthis.pane'

---Show `view` in the pane, laid out for its current width. The view is kept so a resize can
---lay it out again.
function M.render(_, view)
  pane.view = view
  if not (pane.buf and vim.api.nvim_buf_is_valid(pane.buf)) then return end
  local width = (pane.win and vim.api.nvim_win_is_valid(pane.win)) and vim.api.nvim_win_get_width(pane.win) or 40
  local r = require('whatsthis.render').layout(view, width)
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

---Hook the pane into Telescope for `core`. `keymaps` ({ scroll_up, scroll_down }, either false
---to skip it) are mapped in the prompt buffer of each picker with the pane.
function M.attach(core, keymaps)
  local group = vim.api.nvim_create_augroup('whatsthis', { clear = true })
  vim.api.nvim_create_autocmd('User', {
    group = group,
    pattern = 'TelescopePreviewerLoaded',
    callback = function(ev)
      local picker, prompt = current_picker()
      if not (picker and picker._whatsthis and picker.layout_strategy == 'whatsthis') then return end
      local first = pane.picker ~= picker
      open_pane(picker)
      if first then
        for name, dir in pairs { scroll_down = 1, scroll_up = -1 } do
          local lhs = keymaps and keymaps[name]
          if lhs then
            vim.keymap.set({ 'i', 'n' }, lhs, function() M.scroll(dir) end, { buffer = prompt, desc = 'whatsthis: scroll the summary' })
          end
        end
        vim.api.nvim_create_autocmd({ 'BufWipeout', 'BufUnload' }, {
          group = group, buffer = prompt, once = true,
          callback = function()
            core:leave()
            close_pane()
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
            end)
          end,
        })
      end
      local name = ev.data and ev.data.bufname
      if not name or name == '' then return core:leave() end
      if not name:match '^/' then name = vim.fs.joinpath(picker.cwd or vim.fn.getcwd(), name) end
      core:preview(vim.fs.normalize(name))
    end,
  })
end

return M
