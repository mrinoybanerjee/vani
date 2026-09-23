import re, sys
from collections import defaultdict
NUM = {"0":"zero","1":"one","2":"two","3":"three","4":"four","5":"five","6":"six","7":"seven","8":"eight","9":"nine","10":"ten"}
def norm(t):
    t = t.lower().replace("-", " ")
    t = re.sub(r"[^a-z0-9' ]", " ", t)
    t = t.replace("'", "")
    return [NUM.get(w, w) for w in t.split()]
def ed(a, b):
    d = list(range(len(b)+1))
    for i in range(1, len(a)+1):
        p, d[0] = d[0], i
        for j in range(1, len(b)+1):
            p, d[j] = d[j], min(d[j]+1, d[j-1]+1, p+(a[i-1]!=b[j-1]))
    return d[len(b)]
ref = dict(l.rstrip("\n").split("\t",1) for l in open("reference.tsv"))
for f in sys.argv[1:]:
    hyp = dict((l.rstrip("\n").split("\t",1)+[""])[:2] for l in open(f))
    agg = defaultdict(lambda: [0,0,0])
    for k, r in ref.items():
        g = k.split("/")[0]
        rw, hw = norm(r), norm(hyp.get(k, ""))
        e = ed(rw, hw)
        agg[g][0] += e; agg[g][1] += len(rw); agg[g][2] += (e / max(1,len(rw)) > 0.5)
    print(f, " ".join(f"{g}: WER {100*e/n:.2f}% (catastrophic {c})" for g,(e,n,c) in sorted(agg.items())))
