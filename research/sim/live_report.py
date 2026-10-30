#!/usr/bin/env python3
"""jetcli のイベント(JSONL)から、下書き・最終訳の所要時間などを集計する。シミュレーターの想定値と並べて出す。
使い方(リポジトリのルートで): python3 sim/live_report.py results/s2-xxx.jsonl
注: 「送信から表示まで」(e2e)は --replay --speed 1 のときだけ意味がある(speed 0 では時計が止まっている)"""
import sys, json, statistics as st, collections
SIM_DRAFT, SIM_FINAL = 0.255, 0.926   # 実測の中央値(AFM節 / Haiku単文)


def q(xs, p):
    s = sorted(xs); return s[min(len(s) - 1, int(len(s) * p))]


def stat(xs):
    return "n=0" if not xs else "中央値 %.2f / p90 %.2f / 最大 %.2f (n=%d)" % (st.median(xs), q(xs, .9), max(xs), len(xs))


E = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
by = collections.defaultdict(list)
for e in E: by[e["kind"]].append(e)
clause_t = {(e["file"], e["seg"], e["idx"]): e["t"] for e in by["clause"]}
req_t = {(e["file"], e["seg"], e["unit"]): e["t"] for e in by["final_req"]}

D = by["draft"]; F = by["final"]
dd = [e for e in D if not e.get("dropped")]
print("ファイル %d / 区間 %d / 節 %d / 最終訳の単位 %d" % (len({e["file"] for e in E}), len(by["seg"]), len(by["clause"]), len(by["final_req"])))
print("\n【下書き(AFM)】%d 件  破棄 %d / ガードレール等で英語表示 %d (%.1f%%) / 遅れて出た %d / エラー %d" % (
    len(D), len(D) - len(dd), sum(e["guard"] for e in dd), 100 * sum(e["guard"] for e in dd) / max(1, len(dd)),
    sum(bool(e.get("late")) for e in dd), sum(1 for e in dd if e.get("error"))))
print("  所要時間   :", stat([e["lat"] for e in dd]), "   (sim想定の中央値 %.2f)" % SIM_DRAFT)
print("  待ち行列   :", stat([e["wait"] for e in dd]))
print("  節が閉じてから表示まで:", stat([e["t"] - clause_t[(e["file"], e["seg"], e["idx"])] for e in dd if (e["file"], e["seg"], e["idx"]) in clause_t]))
print("\n【最終訳(Haiku)】%d 件  エラー %d" % (len(F), sum(1 for e in F if e.get("error"))))
print("  所要時間   :", stat([e["lat"] for e in F]), "   (sim想定の中央値 %.2f)" % SIM_FINAL)
print("  最初の文字まで:", stat([e["ttft"] for e in F]))
print("  待ち行列(直列):", stat([e["wait"] for e in F]))
print("  送信から表示まで:", stat([e["t"] - req_t[(e["file"], e["seg"], e["unit"])] for e in F if (e["file"], e["seg"], e["unit"]) in req_t]))
print("\n【下書きの例】")
for e in dd[:10]:
    c = next((x for x in by["clause"] if (x["file"], x["seg"], x["idx"]) == (e["file"], e["seg"], e["idx"])), None)
    print("  %s -> %s%s" % (c["text"] if c else "?", e.get("ja", "(英語表示)"), "  [遅れ]" if e.get("late") else ""))
print("\n【最終訳の例】")
for e in F[:8]:
    r = next((x for x in by["final_req"] if (x["file"], x["seg"], x["unit"]) == (e["file"], e["seg"], e["unit"])), None)
    print("  %s -> %s%s" % (r["en"] if r else "?", e["ja"], "  [エラー: %s]" % e["error"][:80] if e.get("error") else ""))
