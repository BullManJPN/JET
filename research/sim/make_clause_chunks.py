#!/usr/bin/env python3
"""micログの確定文を節(カンマ・接続詞)で塊に切り、「直前の英語<TAB>塊」の形で mic-chunks.tsv に書く。
ルール: カンマ/セミコロン/文末、または接続詞(and but so because which where when if or that)の前で切る。
       4語未満の塊は次とつなぐ。14語を超えたら強制で切る。直前の英語は同じ区間の直前2塊まで。"""
import json, glob, re
CONJ = {"and", "but", "because", "which", "where", "when", "if", "or", "while", "although"}
def chunks(text):
    words = text.split()
    out, cur = [], []
    for i, w in enumerate(words):
        lw = re.sub(r"[^\w']", "", w.lower())
        if cur and lw in CONJ and len(cur) >= 4:
            out.append(cur); cur = []
        cur.append(w)
        if (re.search(r"[,;.?!]$", w) and len(cur) >= 4) or len(cur) >= 14:
            out.append(cur); cur = []
    if cur:
        if out and len(cur) < 4: out[-1] += cur
        else: out.append(cur)
    return [" ".join(c) for c in out]
rows = []
for f in sorted(glob.glob("logs/asr-20261028-*-mic.jsonl")):
    prev = []
    for l in open(f):
        e = json.loads(l)
        if e.get("kind") != "final": continue
        for c in chunks(" ".join(e["text"].split())):
            rows.append((" ".join(prev[-2:]), c)); prev.append(c)
open("mic-chunks.tsv", "w").write("\n".join("%s\t%s" % r for r in rows) + "\n")
n = [len(c.split()) for _, c in rows]
print("mic-chunks.tsv: %d 塊 / 平均 %.1f 語 / 最大 %d 語" % (len(rows), sum(n)/len(n), max(n)))
