# Local models for synopses: results (2026-11-07)

Setting as in PLAN.md: 30 files, one request at a time, llama.cpp 0.9.0 (build 12110), M2
MacBook with 16 GB, 16,384-token context, thinking off, at most 400 tokens out. Accuracy judged by
GPT-6 Luna given the file (one synopsis per arm could not be graded, so n=29 pairs).

| Model | Median time [95% CI] | Max | Synopses with no wrong claim | vs Luna [95% CI] | Memory (file + server) |
|---|---|---|---|---|---|
| GPT-6 Luna (API) | 1.4 s [1.3, 1.5] | 3.1 s | 27/29 | — | — |
| Qwen3.5 4B Q8_0 | 10.9 s [7.9, 12.5] | 55 s | 17/29 | -0.34 [-0.55, -0.14] | ~4.2 + 3.2 GB |
| Qwen3.5 4B Q4_K_M | 11.9 s [9.1, 15.1] | 61 s | 17/29 | -0.34 [-0.55, -0.14] | ~2.6 + 3.2 GB |
| Qwen3.5 9B Q4_K_M | 23.2 s [16.3, 30.6] | 151 s | 9/29 | -0.62 [-0.83, -0.38] | ~5.3 + 3.3 GB |
| LFM3 1.7B Q8_0 | 12.5 s [11.6, 14.8] | 32 s | 4/29 | -0.79 [-0.93, -0.66] | ~1.7 + 1.0 GB |
| LFM3 1.7B Q4_K_M | 11.7 s [10.2, 12.6] | 39 s | 5/29 | -0.76 [-0.90, -0.59] | ~1.0 + 0.9 GB |

Memory: "server" is the physical footprint of llama-server sampled every 15 s, which on macOS
does not include the memory-mapped model file; the total is approximately their sum.

Findings:
- Reading the prompt is the bottleneck: Qwen3.5 4B reads ~210-250 tokens/s and 9B ~110 tokens/s
  on this M2, and a typical prompt has ~2,000-3,000 new tokens.
- LFM3 1.7B ignores the format (0/30 opened with a verb; it writes bullet lists until the
  400-token limit), so its time is mostly writing and its accuracy is poor.
- Qwen3.5 9B was less accurate than 4B here. It wrote longer synopses (median 78 tokens vs ~50;
  only 15/30 stayed under 50 words), so it made more claims and more wrong ones.
- Q8 vs Q4 made no measurable difference for Qwen3.5 4B (17/29 both) or LFM3.
- Reusing the shared start of the prompt: on llama.cpp 0.9.0, Qwen3.5 reused a median 2,112
  tokens per request (38% of all prompt tokens); on 0.3.0 it reused 633. LFM3 reused 614 on 0.9.0.
  Both mix recurrent layers with attention, so the server can only restart from saved checkpoints.

Predictions (PLAN.md) compared with results:
- LFM3 1.7B Q4 ~1-2 s: wrong, 11.7 s, because it never stops at the format's length.
- Qwen3.5 4B ~4-8 s: wrong, 11.9 s; reading speed was lower than I assumed.
- Qwen3.5 9B ~8-15 s: wrong, 23 s.
- Qwen3.5 9B the most accurate local model: wrong; 4B was more accurate.
- Q8 no better than Q4: right.
- LFM2.5 8B-A1B: not measured. It always thinks, and in a smoke test it took the README's
  instructions as its task.

Limits: one judge (Luna, which also wrote the reference synopses), one pass, n=29; files from
three small repos by one author.
