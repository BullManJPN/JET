#!/usr/bin/env python3
"""仮テキスト中の「文末(. ? !)で閉じた文」を、ASRの確定を待たずに確定できるかを調べる。
使い方: python3 sim/sentence_stability.py [logs/asr-*-mic.jsonl ...]
方式: 同じ文が K 回連続の到着の塊(0.3秒以内をまとめた単位)で変わらなければ確定。
評価: 確定した文が ASR の最終結果の文と一致したか / ASR確定より何秒早いか"""
import json, re, sys, glob, statistics as st

def norm(s): return re.sub(r"[^\w' ]", "", s.lower()).split()

def sentences(text):
    # 閉じた文だけ返す(最後の未完部分は除く)
    parts = re.split(r"(?<=[.?!])\s+", text.strip())
    closed = parts[:-1] if not re.search(r"[.?!]$", text.strip()) else parts
    return [p for p in closed if p]

def run(path, K):
    ev = [json.loads(l) for l in open(path) if l.strip()]
    ev = [e for e in ev if e.get("kind") in ("volatile", "final")]
    segs, cur = [], []
    for e in ev:
        cur.append(e)
        if e["kind"] == "final": segs.append(cur); cur = []
    out = []
    for s in segs:
        fin = s[-1]
        if fin["kind"] != "final": continue
        fsent = sentences(fin["text"] + ("" if re.search(r"[.?!]\s*$", fin["text"]) else "."))
        # 塊ごとの最後の仮テキスト
        bl = []
        for e in s[:-1]:
            if bl and e["wall"] - bl[-1]["wall"] < 0.3: bl[-1] = e
            else: bl.append(e)
        committed = {}
        hist = {}
        for b in bl:
            ss = sentences(b["text"])
            for i, t in enumerate(ss):
                if i in committed: continue
                h = hist.setdefault(i, [])
                h.append(t)
                if len(h) >= K and len(set(x.lower() for x in h[-K:])) == 1:
                    committed[i] = (b["wall"], t)
        for i, (w, t) in committed.items():
            ok = i < len(fsent) and norm(t) == norm(fsent[i])
            out.append({"gain": fin["wall"] - w, "ok": ok, "t": t, "f": fsent[i] if i < len(fsent) else "-"})
        out.append({"nfinal_sent": len(fsent)})
    return out

files = sys.argv[1:] or sorted(glob.glob("logs/asr-20261028-*-mic.jsonl"))
for K in (1, 2, 3):
    rows = []
    nsent = 0
    for f in files:
        r = run(f, K)
        nsent += sum(x.get("nfinal_sent", 0) for x in r)
        rows += [x for x in r if "gain" in x]
    ok = [x for x in rows if x["ok"]]
    print("K=%d: 早期確定 %d 文 / ASR確定の全文 %d  一致 %d (%.0f%%)  早まった時間 中央値 %.1fs 最大 %.1fs" % (
        K, len(rows), nsent, len(ok), 100 * len(ok) / max(1, len(rows)),
        st.median(x["gain"] for x in ok) if ok else 0, max((x["gain"] for x in ok), default=0)))
    if K == 2:
        for x in rows:
            if not x["ok"]: print("   不一致: [%s]  →確定 [%s]" % (x["t"], x["f"]))
