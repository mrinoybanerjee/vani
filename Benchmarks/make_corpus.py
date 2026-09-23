import glob, os, random, subprocess
random.seed(7)
root = "librispeech/LibriSpeech"
def load(split):
    rows = []
    for tf in sorted(glob.glob(f"{root}/{split}/*/*/*.trans.txt")):
        d = os.path.dirname(tf)
        for line in open(tf):
            uid, text = line.strip().split(" ", 1)
            rows.append((uid, os.path.abspath(f"{d}/{uid}.flac"), text))
    return rows
def dur(path):
    out = subprocess.run(["afinfo", path], capture_output=True, text=True).stdout
    for l in out.splitlines():
        if "estimated duration" in l: return float(l.split(":")[1].split()[0])
    return 0
man, ref = [], []
for split in ["test-clean", "test-other"]:
    rows = load(split)
    for uid, p, t in random.sample(rows, 400):
        man.append(f"{split}/{uid}\t{p}"); ref.append(f"{split}/{uid}\t{t}")
    # long-form: consecutive utterances within chapters
    chapters = {}
    for uid, p, t in rows:
        chapters.setdefault(uid.rsplit("-",1)[0], []).append((uid,p,t))
    picks = random.sample(sorted(chapters), 15)
    for i, ch in enumerate(picks):
        target = [60, 120, 300][i % 3]
        items, total = [], 0.0
        for uid, p, t in chapters[ch]:
            items.append((p, t)); total += dur(p) + 0.3
            if total >= target: break
        lid = f"long-{split}/{ch}-{int(total)}s"
        man.append(lid + "\t" + "|".join(p for p,_ in items)); ref.append(lid + "\t" + " ".join(t for _,t in items))
open("manifest.tsv","w").write("\n".join(man)+"\n"); open("reference.tsv","w").write("\n".join(ref)+"\n")
print(len(man))
