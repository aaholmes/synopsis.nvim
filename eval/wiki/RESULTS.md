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
