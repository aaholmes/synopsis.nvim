"""Summarize a results file written by eval/collect.lua: latency, tokens, cost, and how well
each summary follows the prompt's rules. Reads the file only; never calls the model.
Usage: python3 eval/analyze.py results.jsonl [price_in_per_M price_out_per_M]"""
import json, random, re, statistics, sys

rows = [json.loads(l) for l in open(sys.argv[1])]
price_in, price_out = (float(sys.argv[2]), float(sys.argv[3])) if len(sys.argv) > 3 else (0.10, 0.50)
ok = [r for r in rows if not r.get('error')]
print(f'n = {len(rows)} files, {len(rows) - len(ok)} errors')

def boot_median(xs, n=10000, seed=0):
    rng = random.Random(seed)
    meds = sorted(statistics.median(rng.choices(xs, k=len(xs))) for _ in range(n))
    return meds[int(0.025 * n)], meds[int(0.975 * n)]

lat = [r['latency_ms'] / 1000 for r in ok]
lo, hi = boot_median(lat)
print(f'latency: median {statistics.median(lat):.2f} s [95% CI {lo:.2f}, {hi:.2f}], range {min(lat):.2f}-{max(lat):.2f} s')

pin = [r['usage'].get('prompt_tokens', 0) for r in ok]
pout = [r['usage'].get('completion_tokens', 0) for r in ok]
cached = [r['usage'].get('cached_tokens') or 0 for r in ok]
cost = [(i * price_in + o * price_out) / 1e6 for i, o in zip(pin, pout)]
print(f'tokens in: median {statistics.median(pin):.0f} (range {min(pin)}-{max(pin)}), '
      f'{sum(cached) / sum(pin):.0%} of them served from the provider cache')
print(f'tokens out: median {statistics.median(pout):.0f} (range {min(pout)}-{max(pout)})')
print(f'cost per summary at ${price_in}/${price_out} per M, ignoring cache discounts: '
      f'median ${statistics.median(cost):.5f}, max ${max(cost):.5f}')

def words(s): return re.findall(r"[\w'./-]+", s.replace('**', ''))
def sentences(s):
    s = re.sub(r'^\s*- ', '', s.replace('**', ''), flags=re.M)
    return [x for x in re.split(r'(?<=[.!?])\s+', s.strip()) if x]

checks = {
    'at most 50 words': lambda t: len(words(t)) <= 50,
    'every sentence at most 15 words': lambda t: all(len(words(x)) <= 15 for x in sentences(t)),
    'first sentence begins with a verb (no "This file"/"Provides"/"Contains")':
        lambda t: not re.match(r'\s*(This (file|module|script)|Provides|Contains)\b', t),
    'first word is a third-person verb (ends in "s")': lambda t: re.match(r'\s*\w+s\b', t) is not None,
    'at most 3 notes': lambda t: len(re.findall(r'^- ', t, re.M)) <= 3,
    'every note has a known bold label':
        lambda t: all(re.match(r'- \*\*(Watch out|Works with|Note):\*\*', l) for l in t.splitlines() if l.startswith('- ')),
    'no headings or code blocks': lambda t: not re.search(r'^#|```', t, re.M),
}
print('\nrule compliance:')
for name, f in checks.items():
    bad = [r['path'] for r in ok if not f(r['summary'])]
    print(f'  {len(ok) - len(bad)}/{len(ok)} {name}' + (f'   fails: {", ".join(bad)}' if bad else ''))
nw = [len(words(r['summary'])) for r in ok]
print(f'words per summary: median {statistics.median(nw):.0f} (range {min(nw)}-{max(nw)})')
print(f'notes per summary: {sorted(len(re.findall(r"^- ", r["summary"], re.M)) for r in ok)}')
