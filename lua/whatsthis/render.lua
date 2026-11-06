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

---Words with their highlight: text inside **...** becomes WhatsthisLabel, without the asterisks.
local function words(text, hl)
  local out, pos = {}, 1
  local function add(segment, group)
    for w in segment:gmatch '%S+' do
      table.insert(out, { text = w, hl = group })
    end
  end
  while true do
    local s, e, inner = text:find('%*%*(.-)%*%*', pos)
    if not s then break end
    add(text:sub(pos, s - 1), hl)
    add(inner, 'WhatsthisLabel')
    pos = e + 1
  end
  add(text:sub(pos), hl)
  return out
end

---Lines and highlights for `view` in a pane `width` columns wide. Marks are
---{ row, col, end_col, hl } with 0-based rows and byte columns.
function M.layout(view, width)
  local items = {}
  local function add_text(text)
    for _, b in ipairs(blocks(text)) do table.insert(items, b) end
  end
  local function add_message(text) table.insert(items, { text = text, hl = 'WhatsthisMessage' }) end

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
      table.insert(marks, { row = #lines, col = #PAD, end_col = #PAD + #'•', hl = 'WhatsthisBullet' })
    end
    local limit = avail - (item.bullet and 2 or 0)
    for _, w in ipairs(words(item.text, item.hl)) do
      local wlen = vim.fn.strdisplaywidth(w.text)
      if used > 0 and used + 1 + wlen > limit then
        table.insert(lines, line)
        line, used = cont, 0
      end
      if used > 0 then
        line = line .. ' '
        used = used + 1
      end
      if w.hl then table.insert(marks, { row = #lines, col = #line, end_col = #line + #w.text, hl = w.hl }) end
      line = line .. w.text
      used = used + wlen
    end
    table.insert(lines, line)
  end
  table.insert(lines, '')
  return { lines = lines, marks = marks }
end

vim.api.nvim_set_hl(0, 'WhatsthisLabel', { default = true, link = '@markup.strong' })
vim.api.nvim_set_hl(0, 'WhatsthisBullet', { default = true, link = '@markup.list' })
vim.api.nvim_set_hl(0, 'WhatsthisMessage', { default = true, link = 'Comment' })

return M
