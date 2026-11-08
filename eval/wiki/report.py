"""Share of required facts per arm, and paired differences between arms, from grades.jsonl.
Each question's score is the mean over its samples; intervals are 95% bootstrap over questions.
Usage: python3 eval/wiki/report.py WIKI_DIR questions.jsonl ..."""
import json, random, statistics as st, sys
from collections import defaultdict
from pathlib import Path

d = Path(sys.argv[1])
qs = {}
for p in sys.argv[2:]:
    for l in open(p):
        if l.strip():
            q = json.loads(l)
            qs[q['id']] = q
SMALL = {'/Users/adam/synopsis', '/Users/adam/butwhy', '/Users/adam/.config/nvim'}
grades = [json.loads(l) for p in sorted(d.glob('grades*.jsonl')) for l in open(p) if l.strip()]
fact = defaultdict(list)   # (arm, id) -> per-sample share of required facts
wrong = defaultdict(list)  # (arm, id) -> per-sample: any false claim
for g in grades:
    if g.get('must') and g['id'] in qs:
        fact[g['arm'], g['id']].append(sum(g['must']) / len(g['must']))
        wrong[g['arm'], g['id']].append(bool(g.get('wrong')))
rng = random.Random(0)
arms = ['files', 'folders', 'padded']


def ci(xs, n=10000):
    v = sorted(st.mean(rng.choices(xs, k=len(xs))) for _ in range(n))
    return v[int(.025 * n)], v[int(.975 * n)]


def score(table, arm, i):
    return st.mean(table[arm, i])


groups = {
    'all': list(qs),
    'small repos': [i for i in qs if qs[i]['repo'] in SMALL],
    'large repos': [i for i in qs if qs[i]['repo'] not in SMALL],
}
for kind in ('where', 'how', 'structure'):
    groups[kind] = [i for i in qs if qs[i]['kind'] == kind]
for name, ids in groups.items():
    ids = [i for i in ids if all((a, i) in fact for a in arms)]
    if not ids:
        continue
    print(f'\n== {name} (n={len(ids)} questions)')
    for a in arms:
        f = [score(fact, a, i) for i in ids]
        w = [score(wrong, a, i) for i in ids]
        lo, hi = ci(f)
        print(f'  {a:8s} facts {st.mean(f):.2f} [{lo:.2f}, {hi:.2f}]   answers with a false claim {st.mean(w):.2f}')
    for a, b in (('folders', 'files'), ('folders', 'padded'), ('padded', 'files')):
        diff = [score(fact, a, i) - score(fact, b, i) for i in ids]
        lo, hi = ci(diff)
        dw = [score(wrong, a, i) - score(wrong, b, i) for i in ids]
        wlo, whi = ci(dw)
        print(f'  {a}-{b}: facts {st.mean(diff):+.2f} [{lo:+.2f}, {hi:+.2f}]; false-claim rate {st.mean(dw):+.2f} [{wlo:+.2f}, {whi:+.2f}]')
