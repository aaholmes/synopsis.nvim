-- Grade every answer in $WIKI_DIR/answers-*.jsonl with the model, given the question, the gold
-- answer and its required facts; never told the arm. Appends to $WIKI_DIR/grades.jsonl. Resumes.
local C = dofile(vim.fs.dirname(debug.getinfo(1, 'S').source:sub(2)) .. '/common.lua')
local dir = vim.env.WIKI_DIR
local only = vim.env.WIKI_ARM -- grade one arm only, so arms can be graded in parallel
local out = string.format('%s/grades%s.jsonl', dir, only and ('-' .. only) or '')
local done = {}
for _, r in ipairs(C.read_jsonl(out)) do if r.must then done[r.arm .. ':' .. r.id .. '#' .. r.sample] = true end end
local qs = {}
for path in vim.env.WIKI_QUESTIONS:gmatch '%S+' do
  for _, q in ipairs(C.read_jsonl(path)) do qs[q.id] = q end
end

local SYSTEM = [[You grade an answer to a question about a code repository. You are given the
question, a correct reference answer, a numbered list of required facts, the source code the
reference answer is based on, and the answer to grade.

For each required fact, decide whether the answer states it. Paraphrase is fine. A file path
counts if the answer names that file (with or without its folder) as the place, or as a likely
or candidate place; it does not count if the answer names the file only to say it is not the
place. A fact offered as a guess counts. Then list the answer's claims that are false according
to the reference answer or the source code. A claim the reference does not mention is false
only if the code shows it is false; if you cannot check it, leave it out. Statements about what
the summaries do or do not say (for example "the summaries do not identify ...") are not claims
about the repository: never list them.

Reply with JSON only: {"must": [true or false for each fact, in order], "wrong": ["claim", ...]}]]

local arms = {}
for _, a in ipairs(only and { only } or { 'files', 'folders', 'padded' }) do
  for _, r in ipairs(C.read_jsonl(string.format('%s/answers-%s.jsonl', dir, a))) do table.insert(arms, r) end
end
for _, r in ipairs(arms) do
  local key = r.arm .. ':' .. r.id .. '#' .. r.sample
  local q = qs[r.id]
  if q and r.answer and not done[key] then
    local facts = {}
    for i, m in ipairs(q.must) do table.insert(facts, string.format('%d. %s', i, m)) end
    local code, budget = {}, 40000
    for _, rel in ipairs(q.files or {}) do
      local ok_read, lines = pcall(vim.fn.readfile, q.repo .. '/' .. rel)
      if ok_read and budget > 0 then
        local text = table.concat(lines, '\n'):sub(1, budget)
        budget = budget - #text
        table.insert(code, string.format('--- %s\n%s', rel, text))
      end
    end
    local user = string.format('QUESTION:\n%s\n\nREFERENCE ANSWER:\n%s\n\nREQUIRED FACTS:\n%s\n\nSOURCE CODE:\n%s\n\nANSWER TO GRADE:\n%s',
      q.question, q.gold, table.concat(facts, '\n'), table.concat(code, '\n\n'), r.answer)
    local text, _, err = C.ask({ { role = 'system', content = SYSTEM }, { role = 'user', content = user } }, nil, nil,
      { reasoning_effort = vim.env.WIKI_GRADE_EFFORT or 'medium', response_format = { type = 'json_object' } })
    local ok, j = pcall(vim.json.decode, text or '')
    local must = ok and type(j) == 'table' and type(j.must) == 'table' and #j.must == #q.must and j.must or nil
    C.append(out, { id = r.id, sample = r.sample, arm = r.arm, must = must, wrong = ok and type(j) == 'table' and j.wrong or nil,
      error = err or (not must and ('bad grade: ' .. (text or ''):sub(1, 200)) or nil) })
    io.write(key, ' ', must and 'ok' or 'bad', '\n')
  end
end
vim.cmd 'qa!'
