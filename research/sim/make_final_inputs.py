#!/usr/bin/env python3
"""最終訳テスト用の入力を作る。シミュレーターと同じ単位(区間 / 長い区間の先出し)に分け、results/final-inputs.json に書く。
英語: 先出しの単位は確定済みの語(用語補正あり)、区間の最後の単位は ASR確定テキスト(用語補正あり)の残り部分。
使い方(リポジトリのルートで): python3 sim/make_final_inputs.py [--hold-last 0] [--early-after 8]"""
import argparse, glob, json, os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import core

ap = argparse.ArgumentParser()
ap.add_argument("--hold-last", type=int, default=0)
ap.add_argument("--early-after", type=float, default=8.0)
ap.add_argument("--out", default="results/final-inputs.json")
a = ap.parse_args()
cfg = core.Cfg(hold_last=a.hold_last, early_after=a.early_after)
T, A, multi = core.load_terms()
out = []
for path in sorted(glob.glob(os.path.join(core.ROOT, "logs/asr-20261028-*-mic.jsonl"))):
    name = os.path.basename(path).replace("asr-", "").replace(".jsonl", "")
    n = 0
    for si, (batches, fin) in enumerate(core.load_segments(path)):
        if not fin["text"].strip():
            continue
        R = core.process_segment(batches, fin, cfg, T, A, multi)
        em, fw, cl = R["emitted"], R["fw"], R["clauses"]
        k_start = 0
        for ui, u in enumerate(R["units"]):
            k0, k1 = cl[u["clauses"][0]]["k0"], cl[u["clauses"][-1]]["k1"]
            last = ui == len(R["units"]) - 1
            if u["early"]:
                words = em[k0:k1 + 1]
            else:
                words = fw[k_start:]
            k_start = k1 + 1
            out.append(dict(file=name, seg=si, unit=n, early=u["early"], en=" ".join(words).strip(),
                            t_trigger=round(u["t_trigger"], 2), n_words=len(words)))
            n += 1
os.makedirs(os.path.join(core.ROOT, "results"), exist_ok=True)
json.dump(out, open(os.path.join(core.ROOT, a.out), "w"), ensure_ascii=False, indent=1)
print("%s: %d 単位 (先出し %d) / 平均 %.1f 語 / 最大 %d 語" % (a.out, len(out), sum(x["early"] for x in out),
      sum(x["n_words"] for x in out) / len(out), max(x["n_words"] for x in out)))
for x in out[:4]:
    print("  [%s u%d%s] %s" % (x["file"][-12:], x["unit"], " 先出し" if x["early"] else "", x["en"]))
