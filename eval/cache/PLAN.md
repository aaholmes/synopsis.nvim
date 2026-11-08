# Does a per-repo prompt_cache_key make GPT-6 Luna reuse the shared prompt start?

Written 2026-11-08, before the run.

## Setting
- The 30 files of the earlier Luna run (`eval/local`), 10 each from three repos, sent one at a time,
  grouped by repo, in the same order.
- Each repo's files share their first ~9,000-10,000 characters (system prompt, background,
  README, file list): about 2,400 tokens, above OpenAI's 1,024-token caching minimum.
- The earlier run sent no key, in the same order, and reported 0 cached tokens on all 30 requests.

## Measured
- Share of prompt tokens reported as cached; requests with any cached tokens.
- Median time per request; paired difference from the earlier run, 95% bootstrap interval.

## Predictions
- The earlier run already had everything caching needs (an identical start over the minimum,
  sequential requests), so I expect the key not to change much: probability about 25% that more
  than half of the requests after each repo's first report cached tokens.
- If caching does happen, I expect 9 of 10 requests per repo to hit, ~2,300 cached tokens each,
  and a median time drop of 0.1-0.3 s.

## What this cannot distinguish
- A difference from the earlier run could come from the key or from the two days between runs
  (provider changes, cache state). A no-key arm run right after would share the warm cache, so it
  is not a clean control either; if hits appear, I will run a no-key arm after a 1-hour wait.

# Second run: explicit cache point on the shared part (written before the run)

Same 30 files and order; the shared README and file list are sent as their own block with a
cache point, and caching is limited to cache points. Cost is computed from the reported tokens:
uncached input $0.10/M, cache writes 1.25x, cache reads 0.1x, output $0.50/M.

## Predictions
- 27 of 30 requests (all but the first of each repo) report cached tokens, about 2,300-2,700
  each; about 75% of all prompt tokens read from the cache.
- Cost per synopsis falls from a median of ~$0.00033 to ~$0.00012.
- Median time falls by 0.1-0.3 s, but the run cannot separate that from drift between days.
