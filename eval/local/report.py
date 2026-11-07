"""Compare models on the same files: speed, memory, prompt reuse, rule-following and accuracy.
Reads files written earlier and never calls a model:
  DIR/<arm>.jsonl          synopses (eval/collect.lua)
  DIR/<arm>.judged.jsonl   claims with verdicts (eval/judge.lua)
  DIR/mem.txt              "time model_path footprint" lines (optional)
Usage: python3 eval/local/report.py DIR reference_arm arm ..."""
import json, random, re, statistics, sys
from pathlib import Path

d = Path(sys.argv[1])
ref, arms = sys.argv[2], sys.argv[2:]
rng = random.Random(0)


def load(path):
    return [json.loads(l) for l in open(path)] if path.exists() else []


def answer(text):
    """The synopsis without a model's thinking; None if the thinking never ended."""
    if not text:
        return None
    if '<think>' in text:
        m = re.search(r'</think>\s*(.*)$', text, re.S)
        return m.group(1).strip() if m else None
    return text


def boot(xs, stat, n=10000):
    vals = sorted(stat(rng.choices(xs, k=len(xs))) for _ in range(n))
    return vals[int(0.025 * n)], vals[int(0.975 * n)]


def words(s):
    return re.findall(r"[\w'./-]+", s.replace('**', ''))


def sentences(s):
    s = re.sub(r'^\s*- ', '', s.replace('**', ''), flags=re.M)
    return [x for x in re.split(r'(?<=[.!?])\s+', s.strip()) if x]


RULES = {
    '<=50 words': lambda t: len(words(t)) <= 50,
    'sentences <=15 words': lambda t: all(len(words(x)) <= 15 for x in sentences(t)),
    'opens with 3rd-person verb': lambda t: re.match(r'\s*\w+s\b', t) is not None
        and not re.match(r'\s*(This|Provides|Contains)\b', t),
    'labelled notes, <=3': lambda t: len(re.findall(r'^- ', t, re.M)) <= 3
        and all(re.match(r'- \*\*(Watch out|Works with|Note):\*\*', l) for l in t.splitlines() if l.startswith('- ')),
}

mem = {}
if (d / 'mem.txt').exists():
    units = {'K': 1e-6, 'M': 1e-3, 'G': 1.0}
    for line in open(d / 'mem.txt'):
        parts = line.split()
        if len(parts) == 3 and parts[2][-1] in units:
            gb = float(parts[2][:-1]) * units[parts[2][-1]]
            mem[parts[1]] = max(mem.get(parts[1], 0), gb)


def wrong_counts(arm):
    """{path: number of wrong claims}, or None for a synopsis with no answer."""
    out = {}
    for j in load(d / f'{arm}.judged.jsonl'):
        if j.get('no_answer'):
            out[j['path']] = None
        elif 'claims' in j:
            out[j['path']] = sum(c.get('verdict') == 'wrong' for c in j['claims'])
    return out


ref_wrong = wrong_counts(ref)
for arm in arms:
    rows = load(d / f'{arm}.jsonl')
    if not rows:
        print(f'\n== {arm}: no results')
        continue
    ok = [r for r in rows if not r.get('error') and answer(r.get('summary'))]
    print(f'\n== {arm}: {len(rows)} files, {len(rows) - len(ok)} without an answer')
    lat = [r['latency_ms'] / 1000 for r in ok]
    if lat:
        lo, hi = boot(lat, statistics.median)
        print(f'time: median {statistics.median(lat):.1f} s [95% CI {lo:.1f}, {hi:.1f}], range {min(lat):.1f}-{max(lat):.1f} s')
    t = [(r.get('usage') or {}).get('timings') or {} for r in ok]
    if any(t):
        read = [x.get('prompt_n', 0) for x in t]
        reused = [x.get('cache_n', 0) for x in t]
        outn = [x.get('predicted_n', 0) for x in t]
        pps = [x['prompt_per_second'] for x in t if x.get('prompt_per_second')]
        tps = [x['predicted_per_second'] for x in t if x.get('predicted_per_second')]
        print(f'prompt tokens read: median {statistics.median(read):.0f}; reused from cache: median {statistics.median(reused):.0f} '
              f'({sum(reused) / max(1, sum(read) + sum(reused)):.0%} of all prompt tokens)')
        print(f'speed: reading {statistics.median(pps):.0f} tok/s, writing {statistics.median(tps):.1f} tok/s (medians); '
              f'tokens written: median {statistics.median(outn):.0f}')
    model = rows[0].get('model')
    for path, gb in mem.items():
        if arm in path or (model and model in path):
            print(f'memory: peak physical footprint {gb:.1f} GB')
    for name, f in RULES.items():
        n_ok = sum(f(answer(r['summary'])) for r in ok)
        print(f'  {n_ok}/{len(ok)} {name}')
    w = wrong_counts(arm)
    if w:
        graded = [p for p in w if w[p] is not None]
        zero = [w[p] == 0 for p in graded]
        print(f'accuracy: {sum(zero)}/{len(graded)} synopses with no wrong claim; '
              f'{sum(w[p] for p in graded)} wrong claims in all')
        if arm != ref:
            # Paired over files both arms answered: difference in the share with no wrong claim.
            both = [p for p in graded if ref_wrong.get(p) is not None]
            diffs = [(w[p] == 0) - (ref_wrong[p] == 0) for p in both]
            if diffs:
                lo, hi = boot(diffs, statistics.mean)
                print(f'  vs {ref}: {statistics.mean(diffs):+.2f} share with no wrong claim [95% CI {lo:+.2f}, {hi:+.2f}], n={len(both)} paired files')
