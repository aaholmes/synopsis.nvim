"""Share of required facts per arm, and paired differences between arms, from grades.jsonl.
Each question's score is the mean over its samples; intervals are 95% bootstrap over questions.
Usage: python3 eval/wiki/report.py WIKI_DIR questions.jsonl ...
$WIKI_ARMS (default files,folders,padded) picks the arms; each later arm is compared with the
first and with the one before it."""
import json, os, random, statistics as st, sys
from collections import defaultdict
from pathlib import Path

d = Path(sys.argv[1])
qs = {}
for p in sys.argv[2:]:
    for l in open(p):
        if l.strip():
            q = json.loads(l)
            q['repo'] = os.path.expanduser(q['repo'])
            qs[q['id']] = q
SMALL = {os.path.expanduser(r) for r in ('~/synopsis', '~/butwhy', '~/.config/nvim')}
grades = [json.loads(l) for p in sorted(d.glob('grades*.jsonl')) for l in open(p) if l.strip()]
fact = defaultdict(list)   # (arm, id) -> per-sample share of required facts
wrong = defaultdict(list)  # (arm, id) -> per-sample: any false claim
for g in grades:
    if g.get('must') and g['id'] in qs:
        fact[g['arm'], g['id']].append(sum(g['must']) / len(g['must']))
        wrong[g['arm'], g['id']].append(bool(g.get('wrong')))
rng = random.Random(0)
arms = os.environ.get('WIKI_ARMS', 'files,folders,padded').split(',')


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
    pairs = (('folders', 'files'), ('folders', 'padded'), ('padded', 'files')) if arms == ['files', 'folders', 'padded'] \
        else list(dict.fromkeys([(a, arms[0]) for a in arms[1:]] + [(arms[i], arms[i - 1]) for i in range(2, len(arms))]))
    for a, b in pairs:
        diff = [score(fact, a, i) - score(fact, b, i) for i in ids]
        lo, hi = ci(diff)
        dw = [score(wrong, a, i) - score(wrong, b, i) for i in ids]
        wlo, whi = ci(dw)
        print(f'  {a}-{b}: facts {st.mean(diff):+.2f} [{lo:+.2f}, {hi:+.2f}]; false-claim rate {st.mean(dw):+.2f} [{wlo:+.2f}, {whi:+.2f}]')


# Tool use, cost and time per answer, from the answers files (arms that used tools only).
PRICE_IN, PRICE_CACHED, PRICE_OUT = 0.10e-6, 0.01e-6, 0.50e-6
for a in arms:
    rows = [json.loads(l) for p in d.glob(f'answers-{a}.jsonl') for l in open(p) if l.strip()]
    rows = [r for r in rows if r.get('answer') and r['id'] in qs and 'calls' in r]
    if not rows:
        continue
    n_calls = [len(r['calls']) for r in rows]
    by_tool = defaultdict(int)
    for r in rows:
        for c in r['calls']:
            by_tool[c['name']] += 1
    cost = [((u['prompt_tokens'] - u['cached_tokens']) * PRICE_IN + u['cached_tokens'] * PRICE_CACHED
             + u['completion_tokens'] * PRICE_OUT) for u in (r['usage'] for r in rows)]
    lat = [r['latency_ms'] / 1000 for r in rows]
    print(f'\n== {a}: {len(rows)} answers')
    print(f'  tool calls per answer: median {st.median(n_calls):.0f}, mean {st.mean(n_calls):.1f}; '
          + ', '.join(f'{k} {v}' for k, v in sorted(by_tool.items(), key=lambda kv: -kv[1])))
    print(f'  answers using definition or references: {sum(any(c["name"] in ("definition", "references") for c in r["calls"]) for r in rows)}')
    print(f'  cost per answer: median ${st.median(cost):.4f}, total ${sum(cost):.2f}; time: median {st.median(lat):.1f} s')
