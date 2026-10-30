#!/usr/bin/env python3
"""塊ごとの翻訳の評価。 使い方: python3 apple/analyze_chunks.py results/chunks-output.json [戦略名]

時間のモデル(仮定。実測ではない):
  話す速さ        : 2.5 語/秒
  音声認識の更新  : 1秒ごと(実測)。語は話し終えた直後の次の更新時刻に見える
  最後の塊        : 文末記号が見えるまで +1更新(実測で句点は次の塊で届いた)
  文全体の翻訳(基準): 確定が文末から約0.9秒後(実測) + 翻訳時間
遅れ = 塊を表示できる時刻 - その塊の最後の語を話し終えた時刻
"""
import json, sys, math, statistics as st
from collections import defaultdict

RATE = 2.5      # 語/秒
CAD = 1.0       # 音声認識の更新間隔(秒)
FINAL_AFTER = 0.9


def visible(i_words):
    """i_words 語を聞き終えた時刻(話し終え) → その語が画面に届く時刻"""
    t = i_words / RATE
    return math.ceil(t / CAD) * CAD


def main(path, strat=None):
    data = json.load(open(path, encoding="utf-8"))
    strategies = sorted({d["strategy"] for d in data})
    if strat:
        strategies = [s for s in strategies if strat in s]
    for strategy in strategies:
        rows = [d for d in data if d["strategy"] == strategy]
        print("=" * 72)
        print(strategy)
        sents = sorted({d["si"] for d in rows})
        full = {d["si"]: d for d in rows if d["gran"] == "full"}
        print("%-8s %5s %8s %9s %10s %12s %12s" % ("粒度", "塊数", "平均語数", "翻訳ms", "初回表示", "塊の遅れ(平均)", "塊の遅れ(最大)"))
        # 基準: 文全体
        fb_first, fb_delay = [], []
        for si in sents:
            n = full[si]["nwords"]
            t_end = n / RATE
            shown = t_end + FINAL_AFTER + full[si]["ms"] / 1000
            fb_first.append(shown)
            fb_delay.append(shown - t_end)
        print("%-8s %5d %8.1f %9d %9.1fs %11.1fs %11.1fs" % (
            "full(基準)", len(sents), st.mean(full[s]["nwords"] for s in sents),
            st.median(full[s]["ms"] for s in sents), st.mean(fb_first), st.mean(fb_delay), max(fb_delay)))
        for gran in ("clause", "w10", "w7"):
            g = [d for d in rows if d["gran"] == gran]
            delays, firsts = [], []
            for si in sents:
                seq = sorted([d for d in g if d["si"] == si], key=lambda d: d["ci"])
                n = full[si]["nwords"]
                for idx, d in enumerate(seq):
                    shown_at = visible(d["needed"]) + (CAD if idx == len(seq) - 1 else 0) + d["ms"] / 1000
                    delays.append(shown_at - (d["last"] + 1) / RATE)
                    if idx == 0:
                        firsts.append(shown_at)
            print("%-8s %5d %8.1f %9d %9.1fs %11.1fs %11.1fs" % (
                gran, len(g), st.mean(d["nwords"] for d in g), st.median(d["ms"] for d in g),
                st.mean(firsts), st.mean(delays), max(delays)))

        # 訳の並べ比較
        out = [path.replace(".json", "-%s.md" % strategy)]
        md = ["# 塊ごとの翻訳 (%s)\n" % strategy]
        for si in sents:
            md.append("\n## %d. %s\n" % (si, full[si]["text"]))
            md.append("- **全文**: %s" % full[si]["ja"])
            for gran in ("clause", "w10", "w7"):
                seq = sorted([d for d in rows if d["gran"] == gran and d["si"] == si], key=lambda d: d["ci"])
                md.append("- **%s**: %s" % (gran, " ／ ".join(d["ja"] for d in seq)))
        open(out[0], "w", encoding="utf-8").write("\n".join(md) + "\n")
        print("訳の並べ比較: %s" % out[0])


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(__doc__); sys.exit(2)
    main(sys.argv[1], sys.argv[2] if len(sys.argv) > 2 else None)
