-- A file map built without a model: per file, its leading comment (or Python docstring) and up
-- to 8 top-level definitions from Tree-sitter; other files show their first non-empty line.
local M = { MAX_DOC = 160, MAX_DEFS = 8 }

local DEFS = {
  lua = { function_declaration = true },
  python = { function_definition = true, class_definition = true },
  rust = { function_item = true, struct_item = true, enum_item = true, trait_item = true, impl_item = true,
    mod_item = true, macro_definition = true, type_item = true },
}
local COMMENT = {
  lua = { '^%s*%-%-+%s?(.*)$' },
  python = { '^%s*#+%s?(.*)$' },
  rust = { '^%s*//[/!]?%s?(.*)$' },
}

---True if s is valid UTF-8.
function M.valid_utf8(s)
  local i, n = 1, #s
  while i <= n do
    local c = s:byte(i)
    local len = c < 0x80 and 1 or (c >= 0xC2 and c <= 0xDF) and 2 or (c >= 0xE0 and c <= 0xEF) and 3
      or (c >= 0xF0 and c <= 0xF4) and 4 or nil
    if not len or i + len - 1 > n then return false end
    for j = i + 1, i + len - 1 do
      local b = s:byte(j)
      if b < 0x80 or b > 0xBF then return false end
    end
    i = i + len
  end
  return true
end

local function squash(s) return vim.trim((s:gsub('%s+', ' '))) end
local function cut(s)
  if #s <= M.MAX_DOC then return s end
  local stop = M.MAX_DOC - 3
  -- Back off to the start of a character, so the cut never splits one.
  while stop > 0 and (s:byte(stop + 1) or 0) >= 0x80 and (s:byte(stop + 1) or 0) <= 0xBF do stop = stop - 1 end
  return vim.trim(s:sub(1, stop)) .. '…'
end

local function doc(lang, lines)
  local i, out = 1, {}
  if lines[1] and lines[1]:match '^#!' then i = 2 end
  while lines[i] do
    local text
    for _, pat in ipairs(COMMENT[lang]) do text = text or lines[i]:match(pat) end
    if not text then break end
    if text:match '%S' and not text:match '^%-%*%-' then table.insert(out, text) end
    i = i + 1
  end
  if lang == 'python' then
    while lines[i] and not lines[i]:match '%S' do i = i + 1 end
    local q = lines[i] and lines[i]:match '^[rRuU]?([\'"][\'"][\'"])'
    if q then
      local body = lines[i]:gsub('^[rRuU]?' .. q, '')
      local parts = {}
      while true do
        local s, e = body:find(q, 1, true)
        if s then table.insert(parts, body:sub(1, s - 1)); break end
        table.insert(parts, body)
        i = i + 1
        if not lines[i] then break end
        body = lines[i]
      end
      table.insert(out, table.concat(parts, ' '))
    end
  end
  return squash(table.concat(out, ' '))
end

local function names(lang, text)
  local ok, parser = pcall(vim.treesitter.get_string_parser, text, lang)
  if not ok then return {} end
  local root = parser:parse()[1]:root()
  local out = {}
  local function node_text(n) return squash(vim.treesitter.get_node_text(n, text)) end
  local function walk(node)
    for child in node:iter_children() do
      local t = child:type()
      if DEFS[lang][t] then
        local name = child:field('name')[1]
        if name then
          table.insert(out, node_text(name))
        else -- e.g. Rust's impl blocks: named by their header
          local body = child:field('body')[1]
          local sr, sc = child:start()
          local er, ec = (body or child):start()
          local header = table.concat(vim.split(text, '\n', { plain = true }), '\n', sr + 1, er + 1)
          local ls = vim.split(header, '\n', { plain = true })
          ls[#ls] = ls[#ls]:sub(1, ec)
          ls[1] = ls[1]:sub(sc + 1)
          table.insert(out, squash(table.concat(ls, ' ')):sub(1, 60))
        end
      elseif lang == 'lua' and t == 'assignment_statement' then
        -- `M.f = function() end` or `local f = function() end`
        local vars, vals = child:named_child(0), child:named_child(1)
        if vals and vals:named_child(0) and vals:named_child(0):type() == 'function_definition' then
          table.insert(out, node_text(vars))
        end
      else
        walk(child)
      end
    end
  end
  walk(root)
  return out
end

---The map line for `rel` in root: "rel: <comment> Defines: a, b, c".
function M.entry(root, rel)
  local f = io.open(root .. '/' .. rel, 'rb')
  if not f then return rel .. ': (unreadable)' end
  local text = f:read '*a'
  f:close()
  if text:sub(1, 8192):find('\0', 1, true) or not M.valid_utf8(text) then return rel .. ': (binary)' end
  local lines = vim.split(text, '\n', { plain = true })
  local ft = vim.filetype.match { filename = rel, contents = vim.list_slice(lines, 1, 5) }
  local lang = ft and vim.treesitter.language.get_lang(ft)
  local parts = {}
  if lang and DEFS[lang] and pcall(vim.treesitter.language.add, lang) then
    local d = doc(lang, lines)
    if d ~= '' then table.insert(parts, cut(d)) end
    local n = names(lang, text)
    if #n > 0 then
      local shown = vim.list_slice(n, 1, M.MAX_DEFS)
      local more = #n > M.MAX_DEFS and string.format(' (+%d more)', #n - M.MAX_DEFS) or ''
      table.insert(parts, 'Defines: ' .. table.concat(shown, ', ') .. more)
    end
  end
  if #parts == 0 then
    for _, l in ipairs(lines) do
      if l:match '%S' then table.insert(parts, cut(squash(l))); break end
    end
  end
  return rel .. ': ' .. (#parts > 0 and table.concat(parts, ' ') or '(empty)')
end

return M
