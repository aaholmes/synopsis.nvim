# Results: file synopses versus folder synopses for answering questions (2026-11-08)

Setting: 80 questions on 8 repos, answered by GPT-6 Luna from text only (no code), 3 samples
each, graded by Luna with reasoning on, given the reference answer, its required facts and the
source files behind it. Predictions in `PLAN.md`; scripts in this folder.

- Small repos (31-39 files): synopsis, butwhy, a Neovim config; 30 questions.
- Large repos (152-754 files): codecompanion.nvim and four private research repos (Rust, CUDA,
  Python); 50 questions. Only the public repos' questions are in `questions/`.
- Score: share of a question's required facts the answer states, averaged over its 3 samples.
  Intervals: 95% bootstrap over questions, paired.

| Arm | Required facts found | Answers with a false claim |
|---|---|---|
| File synopses | 0.36 [0.31, 0.41] | 30% |
| + folder synopses and overview | 0.36 [0.30, 0.41] | 31% |
| + unrelated synopses of equal length | 0.34 [0.28, 0.39] | 32% |

- **Folder synopses did not help.** Difference from file synopses alone: +0.00 [-0.03, +0.03]
  overall; -0.01 [-0.05, +0.03] on small repos; +0.00 [-0.03, +0.03] on large repos. The
  predicted +0.08 on large repos lies outside the interval. No question kind gained: where -0.02,
  how +0.01, structure +0.00.
- **File synopses alone answer about a third of what is asked**: 0.46 on "where" questions,
  0.23 on "how" questions, 0.43 on "structure" questions. I predicted 0.65 overall.
- Answers usually name the right file and then say the synopses do not give the details asked
  for (which function, in which order, why). Those details need the code itself.
- Prompt sizes: median 2,000-3,000 tokens on small repos, 39,000 (50,000 with folders) on the
  754-file repo. All 720 answers cost $0.21.

## Challenges to validity
- Luna writes the synopses, answers and grades; a shared bias goes undetected. A hand check of
  4 random grades agreed with all of them.
- The questions were written by agents reading code, with code-level required facts; real users'
  questions may be broader, and broader questions could favour folder synopses.
- One prompt for folder synopses was tried; another might do better.

# Second test: synopses plus tools that read the code (2026-11-08)

Same 80 questions, 3 samples each, GPT-6 Luna with reasoning off, graded the same way. The files
arm is the first test's. Share of required facts found, 95% bootstrap over questions:

| Arm | All (80) | Small repos (30) | Large repos (50) | Answers with a false claim |
|---|---|---|---|---|
| files: synopses alone | 0.36 [0.31, 0.41] | 0.32 | 0.39 | 30% |
| tools: + rg, read, outline | 0.79 [0.74, 0.83] | 0.87 | 0.74 | 16% |
| lsp: + definition, references | 0.77 [0.72, 0.82] | 0.89 | 0.70 | 16% |

- tools-files: +0.43 [+0.37, +0.48]; false-claim rate -0.13 [-0.21, -0.06].
- By kind, tools-files: where +0.46 (0.46 to 0.92), how +0.48 (0.23 to 0.71), structure +0.26
  (0.43 to 0.69).
- lsp-tools: -0.02 [-0.05, +0.01]. The model called the language server in 1 of 240 answers, so
  this compares two runs of nearly the same arm. On large repos it is -0.04 [-0.08, -0.00]: an
  interval that only just excludes 0, from noise alone, among six groups.
- Tool use (tools arm): median 7 calls per answer (read 1,482, rg 458, outline 47 in all). Median
  $0.0025 and 7.9 s per answer; $1.14 for 240 answers.
- Three random grades checked by hand: all correct.

Predictions: tools-files +0.25 (wrong: +0.43, above the interval); "how" to ~0.55 (wrong: 0.71);
false claims to ~15% (right: 16%); lsp-tools about 0 (right, but because the model did not use the
language server); ~5 calls, ~10 s, ~$0.003 per answer (7 calls, 7.9 s, $0.0025).

What this means: synopses alone are not enough to answer questions about code, but with three
plain tools the model finds about 80% of the required facts, for a quarter of a cent per answer.
Offering language-server lookups changed nothing, because the model preferred rg and read.

What this cannot tell us:
- Whether the synopses help when the model can read code: there is no tools-only arm.
- Whether the language server would help if the model were made to use it, or on questions
  about names that rg cannot tell apart (e.g. many functions called `run`).

# Third test: tools without synopses (2026-11-08)

The bare arm has the tools arm's tools but no file synopses; paired with the tools arm over the
same 80 questions. 239 of 240 answers (one request timed out) and 235 grades (the API account ran
out of credits during grading); every question has at least one graded sample.

| | tools (synopses + tools) | bare (tools only) | bare-tools |
|---|---|---|---|
| Required facts, all (80) | 0.79 | 0.73 | -0.06 [-0.09, -0.02] |
| Small repos (30) | 0.87 | 0.82 | -0.05 [-0.11, -0.00] |
| Large repos (50) | 0.74 | 0.68 | -0.06 [-0.11, -0.01] |
| "where" (32) | 0.92 | 0.85 | -0.07 [-0.12, -0.03] |
| "how" (32) | 0.71 | 0.70 | -0.01 [-0.05, +0.04] |
| "structure" (16) | 0.69 | 0.57 | -0.12 [-0.24, +0.00] |
| Answers with a false claim | 16% | 20% | +0.03 [-0.04, +0.10] |
| Tool calls per answer (mean) | 8.3 | 11.4 | |
| rg calls in all | 458 | 1,290 | |
| Cost per answer (median) | $0.0025 | $0.0034 | |
| Time per answer (median) | 7.9 s | 10.3 s | |

Predictions: bare-tools -0.08 with an interval excluding 0 (right: -0.06); -0.12 on large repos
and -0.03 on small ones (wrong: the drop is about the same, -0.06 and -0.05); largest drop on
"where" and "structure" (right); ~3 more calls per answer (right: +3.1); lower cost (wrong: the
extra rounds cost more than the synopses they no longer resend).

What this means: the synopses help even when the model can read the code. They raise the share
of required facts by 0.06, and they make answers cheaper and faster, because the model searches
less. "How" questions gain nothing from them: once the right file is found, the code answers.

What this cannot tell us: whether a plain file list would do as well as the synopses. The bare
arm has no list of the repo's files, and no tool that lists them.
