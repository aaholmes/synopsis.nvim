-- Lays out a core view for the summary pane: margins on every side, a blank line between the
-- opening sentence and each note, "•" for bullets and highlighted bold labels. It wraps the text
-- itself, so the right margin holds and wrapped notes stay indented under their text. It draws
-- everything itself rather than relying on a markdown renderer.
local M = {}

local PAD = '  ' -- left and right margin, in columns
local BULLET = '• '

local MESSAGES = {
  waiting = 'No summary yet. One is written if you stay on this file.',
  pending = 'Writing a summary…',
  outdated = 'Outdated: the file or prompt changed. A new summary is written if you stay on this file.',
}

-- An opening like "This file provides" says nothing; cut it to "Provides". "is" and "was" are
-- kept, since "Is the entry point" reads worse than the original.
local function cut_opener(text)
  local lead, subject, verb, rest = text:match '^(%s*)[Tt]his (%a+) (%a+)(.*)$'
  if not (subject == 'file' or subject == 'module' or subject == 'script') then return text end
  if verb == 'is' or verb == 'was' then return text end
  return lead .. verb:sub(1, 1):upper() .. verb:sub(2) .. rest
end

---Paragraphs and notes. A line that does not start a note or follow a blank line continues
---the one above, so sentences and notes the model wrapped are joined.
local function blocks(text)
  local out, after_blank = {}, true
  for _, line in ipairs(vim.split(text, '\n', { plain = true })) do
    local body = vim.trim(line)
    if body == '' then
      after_blank = true
    else
      local note = body:match '^[-*] (.*)$'
      if note or after_blank then
        table.insert(out, { bullet = note ~= nil, text = note or body })
      else
        out[#out].text = out[#out].text .. ' ' .. body
      end
      after_blank = false
    end
  end
  return out
end

---Split text into pieces { text, hl }: text inside **...** gets SynopsisLabel and text inside
---`...` SynopsisCode, without the markers. A label may hold code ("**Works with `x`:**").
local function pieces(text, hl, out)
  out = out or {}
  local pos = 1
  while true do
    local s, e, inner = text:find('%*%*(.-)%*%*', pos)
    local cs, ce, cinner = text:find('`([^`]+)`', pos)
    local code = cs and (not s or cs < s)
    if code then s, e, inner = cs, ce, cinner end
    if not s then break end
    table.insert(out, { text = text:sub(pos, s - 1), hl = hl })
    if code then
      table.insert(out, { text = inner, hl = 'SynopsisCode' })
    else
      pieces(inner, 'SynopsisLabel', out)
    end
    pos = e + 1
  end
  table.insert(out, { text = text:sub(pos), hl = hl })
  return out
end

---Words to lay out, each a list of parts { text, hl }. Pieces with no space between them stay in
---one word ("`a.lua`,"), so wrapping never splits punctuation from the code before it.
local function words(text, hl)
  local out, after_space = {}, true
  for _, piece in ipairs(pieces(text, hl)) do
    if piece.text ~= '' then
      for space, w in piece.text:gmatch '(%s*)(%S+)' do
        if space == '' and not after_space and #out > 0 then
          table.insert(out[#out], { text = w, hl = piece.hl })
        else
          table.insert(out, { { text = w, hl = piece.hl } })
        end
        after_space = false
      end
      after_space = piece.text:match '%s$' ~= nil
    end
  end
  return out
end

---Lines and highlights for `view` in a pane `width` columns wide. Marks are
---{ row, col, end_col, hl } with 0-based rows and byte columns.
function M.layout(view, width)
  local items = {}
  local function add_text(text)
    for _, b in ipairs(blocks(text)) do table.insert(items, b) end
  end
  local function add_message(text) table.insert(items, { text = text, hl = 'SynopsisMessage' }) end

  if view.kind == 'summary' then
    add_text(cut_opener(view.text))
  elseif view.kind == 'outdated' or view.kind == 'pending' then
    if view.text then add_text(cut_opener(view.text)) end
    add_message(MESSAGES[view.kind])
  elseif view.kind == 'skipped' then
    add_message('Not summarized: ' .. view.text .. '.')
  elseif view.kind == 'error' then
    add_message('Summary failed: ' .. view.text)
  else
    add_message(MESSAGES[view.kind] or '')
  end

  local lines, marks = { '' }, {}
  local avail = math.max(10, width - 2 * #PAD)
  for i, item in ipairs(items) do
    if i > 1 then table.insert(lines, '') end
    local first = PAD .. (item.bullet and BULLET or '')
    local cont = PAD .. (item.bullet and '  ' or '')
    local line, used = first, 0
    if item.bullet then
      table.insert(marks, { row = #lines, col = #PAD, end_col = #PAD + #'•', hl = 'SynopsisBullet' })
    end
    local limit = avail - (item.bullet and 2 or 0)
    for _, parts in ipairs(words(item.text, item.hl)) do
      local wlen = 0
      for _, part in ipairs(parts) do wlen = wlen + vim.fn.strdisplaywidth(part.text) end
      if used > 0 and used + 1 + wlen > limit then
        table.insert(lines, line)
        line, used = cont, 0
      end
      if used > 0 then
        line = line .. ' '
        used = used + 1
      end
      for _, part in ipairs(parts) do
        if part.hl then table.insert(marks, { row = #lines, col = #line, end_col = #line + #part.text, hl = part.hl }) end
        line = line .. part.text
      end
      used = used + wlen
    end
    table.insert(lines, line)
  end
  table.insert(lines, '')
  return { lines = lines, marks = marks }
end

vim.api.nvim_set_hl(0, 'SynopsisLabel', { default = true, link = '@markup.strong' })
vim.api.nvim_set_hl(0, 'SynopsisBullet', { default = true, link = '@markup.list' })
vim.api.nvim_set_hl(0, 'SynopsisCode', { default = true, link = '@markup.raw' })
vim.api.nvim_set_hl(0, 'SynopsisMessage', { default = true, link = 'Comment' })

return M
