#!/usr/bin/env python3
"""jetcli の live / --file 実行の記録(events)を、条件ごとに並べて比べる(間(ま)での確定の A/B など)。
各 events の認識ログ(logs/asr-<file>.jsonl)に sim/core.py を当てて「話し終えた推定時刻」を出し、そこからの遅れを集計する。
区間の中の均等割りで推定しているので絶対値は±0.5秒ほど。同じ音声どうしの比較に使う。
使い方(リポジトリのルートで): python3 sim/run_compare.py results/p0.jsonl results/p300.jsonl [--texts]"""
import json, sys, os, statistics as st, difflib
H = os.path.dirname(os.path.abspath(__file__)); ROOT = os.path.dirname(H)
sys.path.insert(0, H)
import core
q = lambda x, p: sorted(x)[min(len(x) - 1, int(len(x) * p))]
S = lambda x: "—" if not x else "%.2f / %.2f" % (st.median(x), q(x, .9))


def analyze(path):
    E = [json.loads(l) for l in open(path) if l.strip()]
    name = next(e["file"] for e in E if "file" in e)
    log = os.path.join(ROOT, "logs", "asr-%s.jsonl" % name)
    cfg = core.Cfg(hold_last=0); T, A, multi = core.load_terms()
    commits, drafts, finals = {}, {}, {}
    for e in E:
        if e["kind"] == "commit": commits.setdefault(e["seg"], []).append(e)
        elif e["kind"] == "draft" and not e.get("dropped"): drafts[(e["seg"], e["idx"])] = e
        elif e["kind"] == "final": finals[(e["seg"], e["unit"])] = e
    M = dict(en=[], close=[], draft=[], final=[], first_ja=[], first_clause=[], words=0, clauses=0, stale=0, segs=0, mismatch=0, texts=[])
    for si, (b, fin) in enumerate(core.load_segments(log)):
        if not fin["text"].strip(): continue
        R = core.process_segment(b, fin, cfg, T, A, multi)
        M["segs"] += 1; M["texts"].append(fin["text"].strip())
        lc = commits.get(si, [])
        if [e["words"] for e in R["events"] if e["kind"] == "commit"] != [e["words"] for e in lc]:
            M["mismatch"] += 1; continue
        k = 0
        for le in lc:
            for _ in le["words"]:
                M["en"].append(le["t"] - R["spoken"][k]); k += 1
        M["words"] += len(R["emitted"]); M["clauses"] += len(R["clauses"])
        M["stale"] += sum(1 for c in R["clauses"] if c["stale"])
        ja = []
        clause_t = {e["idx"]: e["t"] for e in E if e["kind"] == "clause" and e["seg"] == si}
        for c in R["clauses"]:
            if c["idx"] in clause_t: M["close"].append(clause_t[c["idx"]] - c["spoken_end"])
            d = drafts.get((si, c["idx"]))
            if d and not d.get("guard") and not d.get("late"):
                M["draft"].append(d["t"] - c["spoken_end"]); ja.append(d["t"])
        if clause_t: M["first_clause"].append(min(clause_t.values()) - R["a0"])
        for ui, u in enumerate(R["units"]):
            f = finals.get((si, ui))
            if f: M["final"].append(f["t"] - u["spoken_end"]); ja.append(f["t"])
        if ja: M["first_ja"].append(min(ja) - R["a0"])
    P = [e for e in E if e["kind"] == "pause"]
    M["pauses"] = len(P); M["forced"] = sum(1 for e in P if e.get("forced"))
    M["pause_lat"] = [e["lat"] for e in E if e["kind"] == "pause_done"]
    fin_t = sorted(e["t"] for e in E if e["kind"] == "seg")
    M["pause_to_seg"] = []
    for e in P:
        nxt = [t for t in fin_t if t >= e["t"]]
        if nxt: M["pause_to_seg"].append(nxt[0] - e["t"])
    return name, M


args = [a for a in sys.argv[1:] if not a.startswith("--")]
R = [analyze(a) for a in args]
labels = [os.path.basename(a).replace(".jsonl", "") for a in args]
rows = [("区間 / 語 / 節", lambda M: "%d / %d / %d" % (M["segs"], M["words"], M["clauses"])),
        ("節の平均語数", lambda M: "%.1f" % (M["words"] / max(1, M["clauses"]))),
        ("間(ま)を見つけた回数 / 確定を要求", lambda M: "%d / %d" % (M["pauses"], M["forced"])),
        ("確定要求が戻るまで (中央値/p90 秒)", lambda M: S(M["pause_lat"])),
        ("間を見つけてから区間確定まで", lambda M: S(M["pause_to_seg"])),
        ("英語表示の遅れ", lambda M: S(M["en"])),
        ("節が閉じるまで", lambda M: S(M["close"])),
        ("区間の最初の節が閉じるまで(話し始めから)", lambda M: S(M["first_clause"])),
        ("下書き(節を話し終えてから)", lambda M: S(M["draft"])),
        ("最終訳(単位を話し終えてから)", lambda M: S(M["final"])),
        ("最初の日本語(話し始めから)", lambda M: S(M["first_ja"])),
        ("古い下書き", lambda M: "%.1f%%" % (100 * M["stale"] / max(1, M["clauses"]))),
        ("コミットが再現と食い違った区間", lambda M: str(M["mismatch"]))]
print("条件: " + " | ".join(labels))
print("(各行: 項目 → 条件ごとの値。遅れは 中央値 / p90 秒)")
for name, f in rows:
    print("%s: %s" % (name, " | ".join(f(M) for _, M in R)))
if len(R) >= 2:
    a = " ".join(R[0][1]["texts"]).lower().split(); 
    for (n, M), l in list(zip(R, labels))[1:]:
        b = " ".join(M["texts"]).lower().split()
        print("\n認識テキストの語の一致率(%s vs %s): %.3f  (語数 %d vs %d)" % (labels[0], l, difflib.SequenceMatcher(None, a, b, autojunk=False).ratio(), len(a), len(b)))
if "--texts" in sys.argv:
    for (n, M), l in zip(R, labels):
        print("\n== %s の認識テキスト(区間ごと)" % l)
        for t in M["texts"]: print("  |", t)
