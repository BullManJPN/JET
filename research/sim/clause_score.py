#!/usr/bin/env python3
"""節の区切り方の案を、区間(ASR の1区間)単位で比べる。案ごとに節の数が違うので、節ごとの採点では比べられない。
各案の下書きベンチの出力(id = 録音|区間|節)を区間ごとにつなぎ(安全策で英語を出した節は英語のまま)、
英語(区間の全文)と日本語(下書きをつないだもの)の組にして sim/draft_score.py で採点する。
使い方(リポジトリのルートで、ANTHROPIC_API_KEY のある Terminal): python3 sim/clause_score.py results/clause-draft-v0-*.jsonl results/clause-draft-v3-*.jsonl ..."""
import json, os, sys, subprocess
from collections import OrderedDict
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
outs = []
for p in sys.argv[1:]:
    meta, segs = {}, OrderedDict()
    nclause = nguard = 0
    for l in open(p, encoding="utf-8"):
        if not l.strip(): continue
        o = json.loads(l)
        if o.get("kind") == "meta": meta = o; continue
        src, si, ci = o["id"].split("|")
        s = segs.setdefault(f"{src}|{si}", dict(en=[], ja=[], lat=0.0))
        s["en"].append(o["en"]); nclause += 1
        if o.get("guard"): nguard += 1; s["ja"].append(o["en"])
        else: s["ja"].append(o.get("ja") or "")
        s["lat"] = max(s["lat"], o.get("lat", 0))
    name = meta.get("name", os.path.basename(p))
    q = os.path.join(ROOT, "results", f"clause-seg-{name}.jsonl")
    with open(q, "w", encoding="utf-8") as f:
        f.write(json.dumps(dict(kind="meta", name=name, greedy=meta.get("greedy"), fewshot=meta.get("fewshot")), ensure_ascii=False) + "\n")
        for k, s in segs.items():
            f.write(json.dumps(dict(id=k, en=" ".join(s["en"]), ja="".join(s["ja"]), lat=s["lat"]), ensure_ascii=False) + "\n")
    print(f"{name}: 節 {nclause}(安全策 {nguard})→ 区間 {len(segs)}  {q}")
    outs.append(q)
sys.exit(subprocess.call([sys.executable, os.path.join(ROOT, "sim", "draft_score.py"), "--batch", "10"] + outs))
