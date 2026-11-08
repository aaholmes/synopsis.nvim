# Results: per-repo prompt_cache_key with GPT-6 Luna (2026-11-08)

Same 30 files, order and settings as the earlier Luna run; predictions in `PLAN.md`.

- **With the key, 0 of 30 requests reported cached tokens**, as in the earlier run without it.
  This matched the prediction that the key would change little (75%).
- Median time 1.31 s versus 1.44 s; paired median difference -0.19 s [95% CI -0.26, -0.03].
  With no cache hits, this is drift between the two days, not an effect of the key.
- **The same prompt sent three times reused 3,918 of 3,921 tokens each time**, so Luna does cache.
- **Cause:** OpenAI places its automatic cache point only at the end of the latest user message
  (developers.openai.com/api/docs/guides/prompt-caching). The README, file list and file share
  one user message, so only an exact repeat can match.
- **Probe, n=2:** splitting that message into two text blocks, with
  `prompt_cache_breakpoint = { mode = 'explicit' }` on the shared one, gave the second file of a
  repo 2,600 cached tokens. The response also reports `cache_write_tokens`: the whole prompt,
  since the automatic cache point at the end still applied.

# Second run: explicit cache point on the shared part (2026-11-08)

Two arms on the same 30 files, back to back: plain requests first (`SYNOPSIS_NO_CACHE=1`), then
requests with the cache point. Explicit-only mode looks up only cache points, so the first arm's
cache entries could not serve the second. Cost from the reported tokens: input $0.10/M, cache
writes 1.25x, cache reads 0.1x, output $0.50/M. Intervals are 95% bootstrap over files, paired.

| | Plain | Cache point |
|---|---|---|
| Requests with cached tokens | 2/30 (exact repeats of earlier prompts) | 27/30 (all but each repo's first) |
| Prompt tokens read from cache | 8% | 57% (median 2,370 per request) |
| Tokens written to cache | 105,633 (every prompt) | 7,240 (the three shared parts) |
| Median cost per synopsis | $0.00041 | $0.00014 |
| Median time | 1.18 s | 1.34 s |

- **Cost:** the cache point costs 0.32x as much per file [0.26, 0.40], a median $0.00029 less.
  Plain requests cost more than the README's earlier $0.0003, because the automatic cache point
  writes every prompt to the cache at 1.25x the input price.
- **Time:** +0.12 s [-0.04, +0.16]: no speedup.
- **Predictions:** 27/30 hits, as predicted; cached share 57% versus the predicted 75% (large
  files make the unshared part bigger); cost as predicted; the predicted 0.1-0.3 s speedup did
  not happen.
- Not checked: whether the synopses' accuracy changed. The text sent is the same, split into two
  blocks.
