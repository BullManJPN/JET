#!/usr/bin/env python3
"""results/*.json から、モデルごとに最新の結果を集めて並べる。 使い方: python3 compare.py [モデル名ならびに部分一致...]"""
import json, glob, os, sys, statistics as st, datetime

files = sorted(glob.glob(os.path.join(os.path.dirname(os.path.abspath(__file__)), "results", "bench-*.json")),
               key=os.path.getmtime)
latest = {}
for f in files:                       # 後のファイルが優先(=最新)
    for r in json.load(open(f, encoding="utf-8")):
        latest.setdefault(r["model"], {"file": f, "rows": []})
        if latest[r["model"]]["file"] != f:
            latest[r["model"]] = {"file": f, "rows": []}
        latest[r["model"]]["rows"].append(r)

want = sys.argv[1:]
models = [m for m in latest if not want or any(w in m for w in want)]
order = ["qwen3:latest", "jet-8b", "jet-14b", "apple-lowLatency", "apple-highFidelity", "claude-haiku-4-5-20251001", "claude-haiku-5-5"]
models.sort(key=lambda m: order.index(m) if m in order else 99)

print("%-28s %5s %9s %9s %9s %7s" % ("model", "n", "TTFT中央", "total中央", "total最大", "非日本語"))
for m in models:
    rows = latest[m]["rows"]
    print("%-28s %5d %9d %9d %9d %7d" % (
        m, len(rows), st.median(r["ttft_ms"] for r in rows), st.median(r["total_ms"] for r in rows),
        max(r["total_ms"] for r in rows), sum(r.get("not_ja", 0) for r in rows)))

sents = []
for m in models:
    for r in latest[m]["rows"]:
        if r["en"] not in sents:
            sents.append(r["en"])
md = ["# 訳の並べ比較 %s\n" % datetime.datetime.now().strftime("%Y-%m-%d %H:%M")]
for i, s in enumerate(sents, 1):
    md.append("\n## %d. %s\n" % (i, s))
    for m in models:
        t = next((r["text"] for r in latest[m]["rows"] if r["en"] == s), "-")
        md.append("- **%s**: %s" % (m, t))
out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "results", "compare-%s.md" % datetime.datetime.now().strftime("%Y%m%d-%H%M%S"))
open(out, "w", encoding="utf-8").write("\n".join(md) + "\n")
print("\n訳の並べ比較: %s" % out)
