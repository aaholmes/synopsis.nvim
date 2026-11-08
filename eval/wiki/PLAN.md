# Are file synopses enough to answer questions about a repo, or do folder synopses help?

Written 2026-11-08, before any synopsis, folder synopsis or answer was generated.

## Setting
- Repos: synopsis (39 files), butwhy (31), the Neovim config (36). Every tracked text file gets a
  synopsis from GPT-6 Luna with the plugin's prompt (`fill.lua`).
- Questions: 30, 10 per repo, written by separate agents from the code alone, before any
  synopsis existed: 4 "where", 4 "how" (spanning 2+ files), 2 "structure". Each has a gold
  answer and 2-4 required facts.
- Folder synopses, bottom-up, from the synopses of a folder's files and subfolders; one repo
  overview from the top folder (`folders.lua`). Luna writes them.

## Arms (GPT-6 Luna answers from text only; no code reading; 3 samples per question)
- A: file list + every file's synopsis.
- B: A + folder synopses + the repo overview.
- C: A + synopses from another repo, cut to the length B adds (controls for extra tokens).

## Measured
- Share of required facts present (Luna grades, blind to the arm); answers with a wrong claim.
- Paired differences B-A and B-C, 95% bootstrap over questions (the 3 samples averaged).

## Predictions
- A covers ~65% of required facts; "how" questions lowest (~50%), "where" highest (~80%).
- B-A: +0.03, with an interval that includes 0. These repos are small enough (31-39 files) that
  the whole list of file synopses is ~2,500 tokens, so the model already sees the structure.
  Largest gain, if any, on "structure" questions.
- C-A: ~0. Wrong-claim rates similar across arms (~20% of answers).

## What this cannot tell us
- Whether folder synopses help on large repos (hundreds of files), where a folder level matters
  most. A null result here does not carry over.
- Whether answers would be better with code access (tools); this tests the map alone.
- Luna writes the synopses, answers and grades: a shared bias goes undetected.

## Added before any answer was generated: two larger repos

- neurosymbolic-mcts (348 files: Rust, CUDA, Python) and codecompanion.nvim (754 files, public),
  10 questions each, written the same way. Total 50 questions.
- Prediction: on these two, B-A is larger, about +0.08, because the full list of file synopses
  is 20,000-45,000 tokens and the folder level gives the model a structure it must otherwise
  assemble. On the three small repos, the prediction above (+0.03) stands. Results are reported
  per group (small: 30 questions; large: 20), as well as pooled.

## Added before any large-repo answer was generated: two Python repos

- llms (152 files, mostly Python) and semistoch_attn (302 files: 128 Python, 151 JSON results),
  10 questions each, written the same way, so the large group is 4 repos and 40 questions, and
  the set is no longer mostly Lua. Total 70 questions.
- Prediction for these two: as for the other large repos, B-A about +0.08. The JSON results files
  in semistoch_attn add many near-identical synopses; I expect folder synopses to help most
  there, by summarizing a results folder in one line.

## Added before any large-repo answer was generated: risq

- risq (352 files: 53 Rust; most of the rest is rustdoc's generated HTML and JS in docs/), 10
  questions, written the same way. Large group: 5 repos, 50 questions; total 80.
- Prediction: B-A about +0.08, as for the other large repos.

# Second test: synopses plus tools that read the code (written before any tools answer)

## Arms (same 80 questions, 3 samples each, Luna with reasoning off, at most 150 words)
- files: the file synopses alone (the answers and grades from the first test).
- tools: the file synopses, plus `rg` (text search), `read` (lines of a file) and `outline`
  (a file's functions and classes with line numbers, from Tree-sitter).
- lsp: as tools, plus `definition` and `references` from the language server (lua-language-server,
  pyright, rust-analyzer).

Both tools arms: up to 10 rounds of tool calls, then the model must answer without tools; tool
output is capped (50 matches, 200 lines). The system prompt differs from the files arm only in
saying the model can read the code. The synopsis repo's tools read a snapshot at a4e3b6e, the
commit before these questions and their answers were added to it.

## Measured
As in the first test, graded the same way, plus paired differences tools-files and lsp-tools
(95% bootstrap over questions), tool calls per answer, cost and time per answer.

## Predictions
- tools-files: +0.25 (0.36 to about 0.60). Largest gain on "how" questions (0.23 to ~0.55),
  because the missing details (which function, in what order) are in the code the model can
  now read. False-claim rate falls from ~30% to ~15%.
- lsp-tools: +0.02, with an interval that includes 0. With `rg` available, the model will rarely
  call the language server, and a search for a name finds its definition and uses in most of
  these repos.
- About 5 tool calls per answer; about 10 s and $0.003 per answer.

## What this cannot tell us
- Whether the synopses help once the model can read code: there is no tools-only arm.
- The grader sees the gold files' source, and the tools arms may quote it; a grader that rewards
  quoted code over correct paraphrase would favour the tools arms.

# Third test: tools without synopses (written before any answer)

- Arm bare: the tools arm's tools (rg, read, outline), 10 rounds, same questions and samples,
  with the file synopses removed. The prompt names the repository only; the system prompt drops
  the sentence about summaries. Compared with the tools arm, paired over questions.
- Prediction: bare-tools -0.08 overall, interval excluding 0; about -0.12 on large repos and
  -0.03 on small ones, because without a map the model must find files by guessing search terms,
  which is harder among hundreds of files. Largest drop on "where" and "structure" questions.
- About 3 more tool calls per answer (mostly rg). Cost per answer lower (~$0.0015), since each
  round no longer resends the synopses (up to 39,000 tokens on the largest repo).
- Cannot tell apart: the synopses' content from a plain file list. There is no arm with the
  paths alone, and this arm has no tool that lists files.

# Fourth test: a deterministic file map instead of synopses (written before any answer)

- Arm map: the tools arm's tools and prompt, with each file's synopsis replaced by its leading
  comment (or docstring) and up to 8 top-level definitions, read with Tree-sitter; files without
  either show their first non-empty line. Same files, questions and samples; paired with the
  tools arm (synopses) and the bare arm (no map).
- Prediction: map-bare +0.04 and tools-map +0.02, both overall: the paths and definitions let the
  model pick files nearly as well as synopses do, but without the synopses' notes on related files
  "structure" questions gain least (map-bare ~+0.03 there). Tool calls per answer between the
  two arms (~9.5). Cost close to the tools arm.
- Cannot tell apart: the paths from the definitions and comments (no paths-only arm), or how a
  mix of synopses and map entries behaves.
