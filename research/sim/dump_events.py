#!/usr/bin/env python3
"""Swift版(jetcli)との照合用の正解イベントを書き出す。時刻は含めない。
sim/core.py の process_segment を --hold-last 0 相当で通し、最終訳の入力英語は make_final_inputs.py と同じ規則で切り出す。
出力: results/golden-events.jsonl (1行1イベント)  kind = seg / commit / clause / final_req / clause_stale
  seg の idx は空テキストの区間も数えた通し番号(make_final_inputs.py と同じ)
使い方(リポジトリのルートで): python3 sim/dump_events.py [--hold-last 0] [--K 2] [--early-after 8] [--out results/golden-events.jsonl]"""
import argparse, difflib, glob, json, os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import core

ap = argparse.ArgumentParser()
ap.add_argument("--hold-last", type=int)
ap.add_argument("--K", type=int)
ap.add_argument("--early-after", type=float)
ap.add_argument("--no-correct", action="store_true")
ap.add_argument("--hold-unknown", type=float)
ap.add_argument("--config", help="jet.json の確定・節の設定を使う(なしなら従来の既定値)")
ap.add_argument("--files", nargs="*")
ap.add_argument("--out", default="results/golden-events.jsonl")
a = ap.parse_args()
if a.config:
    cfg = core.load_cfg(a.config, K=a.K, hold_last=a.hold_last, early_after=a.early_after, hold_unknown=a.hold_unknown)
else:
    cfg = core.Cfg(K=a.K or 2, hold_last=a.hold_last or 0, early_after=a.early_after or 8.0, hold_unknown=a.hold_unknown or 0.0)
if a.no_correct: cfg.correct = False
T, A, multi = core.load_terms()
files = []
for pat in (a.files or ["logs/asr-20261028-*-mic.jsonl"]):
    files += sorted(glob.glob(pat if os.path.isabs(pat) else os.path.join(core.ROOT, pat)))
out = []
cnt = dict(files=0, segs=0, words=0, clauses=0, units=0, early=0, stale=0)
for path in files:
    name = os.path.basename(path).replace("asr-", "").replace(".jsonl", "")
    cnt["files"] += 1
    for si, (batches, fin) in enumerate(core.load_segments(path)):
        if not fin["text"].strip():
            continue
        R = core.process_segment(batches, fin, cfg, T, A, multi)
        em, fw, cl = R["emitted"], R["fw"], R["clauses"]
        out.append(dict(file=name, seg=si, kind="seg", text=fin["text"].strip()))
        cnt["segs"] += 1; cnt["words"] += len(em); cnt["clauses"] += len(cl)
        # 最終訳の入力の切り出し: 先出しの単位の終わり(emitted の位置)を、最終テキスト(fw)の位置に語の対応づけで写す
        nem = [core.N(w) for w in em]; nfw = [core.N(w) for w in fw]
        mp = {}
        for blk in difflib.SequenceMatcher(None, nem, nfw, autojunk=False).get_matching_blocks():
            for x in range(blk.size):
                mp[blk.a + x] = blk.b + x
        def aligned_next(k):
            j = k
            while j >= 0 and j not in mp:
                j -= 1
            return mp[j] + 1 if j >= 0 else 0
        last_k1, ui = -1, 0
        for e in R["events"]:
            if e["kind"] == "commit":
                out.append(dict(file=name, seg=si, kind="commit", words=e["words"], flush=e["flush"]))
            elif e["kind"] == "clause":
                out.append(dict(file=name, seg=si, kind="clause", idx=e["idx"], text=e["text"]))
            elif e["kind"] == "final_req":
                u = R["units"][ui]
                k0, k1 = cl[u["clauses"][0]]["k0"], cl[u["clauses"][-1]]["k1"]
                ks = aligned_next(last_k1) if last_k1 >= 0 else 0
                words = em[k0:k1 + 1] if u["early"] else fw[ks:]
                last_k1 = k1
                out.append(dict(file=name, seg=si, kind="final_req", unit=ui, early=e["early"],
                                n_clauses=e["n_clauses"], n_words=e["n_words"], en=" ".join(words).strip()))
                cnt["units"] += 1; cnt["early"] += bool(e["early"]); ui += 1
        for c in cl:
            if c["stale"]:
                out.append(dict(file=name, seg=si, kind="clause_stale", idx=c["idx"]))
                cnt["stale"] += 1
os.makedirs(os.path.join(core.ROOT, "results"), exist_ok=True)
with open(os.path.join(core.ROOT, a.out), "w") as f:
    for e in out:
        f.write(json.dumps(e, ensure_ascii=False) + "\n")
print("%s: %d 本 / %d 区間 / %d 語 / %d 節 / %d 単位(先出し %d) / 古い下書き %d" % (
    a.out, cnt["files"], cnt["segs"], cnt["words"], cnt["clauses"], cnt["units"], cnt["early"], cnt["stale"]))
