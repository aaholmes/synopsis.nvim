# Local models for synopses: plan and predictions (written 2026-11-07, before any run)

Question: can a model on a 16 GB M2 MacBook write synopses fast enough to wait for, accurately
enough, without taking too much memory?

Setting: the 30 files already used for GPT-6 Luna (10 butwhy, 10 Neovim config, 10 synopsis),
the current prompt, one request at a time, files in the same order for every arm. llama-server
with the whole model on the GPU, flash attention, a 16,384-token context, one slot (so the
shared start of the prompt is reused between files of the same repo).

Arms: LFM3 1.7B Q4_K_M and Q8_0; LFM2.5 8B-A1B Q4 and Q8 (the Ollama files); Qwen3.5 4B Q4_K_M;
Qwen3.5 9B Q4_K_M (the Ollama file); GPT-6 Luna, rerun now on the same prompt, as the reference.
Not run: Recursive Flint (smallest file 11.4 GB, above the ~10.7 GB the GPU may use), Reflection
Beam (501B), Ricursive Ripple (65B), Qwen3.6 (smallest is 27B).

Measured per arm:
- time from request to synopsis (median, bootstrap 95% CI, range);
- memory: model, KV cache and compute buffers as llama-server reports them at load;
- rule compliance (eval/analyze.py);
- accuracy: GPT-6 Luna, given the file, counts the synopsis's claims and the wrong ones. Reported
  as the share of synopses with no wrong claim, and the difference from Luna's own synopses with
  a paired bootstrap 95% CI over files.

Predictions:
- LFM3 1.7B Q4: ~1-2 s per synopsis; clearly less accurate than Luna (more wrong claims, more
  invented "Watch out" notes). Q8 a little slower, no visibly better.
- LFM2.5 8B-A1B Q4: ~2-4 s; the best speed/accuracy trade-off among local models, but still below
  Luna. Q8 slightly slower, accuracy within noise of Q4.
- Qwen3.5 4B: ~4-8 s; about as accurate as LFM2.5 8B-A1B.
- Qwen3.5 9B: ~8-15 s, too slow to wait for in the picker but fine in the background; the most
  accurate local model, still a few wrong claims more than Luna over 30 files.
- No local model follows the 15-word sentence rule as well as Luna.

Limits: n=30 can only show large accuracy differences (a 95% CI on a difference in proportions is
roughly +/-0.2 here). Luna judges its own synopses, which may favour it. One judge, one pass.
