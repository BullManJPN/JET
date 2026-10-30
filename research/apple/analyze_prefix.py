#!/usr/bin/env python3
"""断片翻訳の集計。 使い方: python3 apple/analyze_prefix.py results/prefix-xxxx.json [例に出す文の番号(0始まり)]

見る指標:
  呼び出し時間   : 断片1回を訳すのにかかった時間
  書き換わり(NE) : 断片が1語伸びるたびに、表示中の日本語が消された文字数の合計 ÷ 最終訳の文字数
                   (0なら一度出た文字は二度と消えない)
  先頭一致率     : 各時点の表示が、最終訳(文全体の訳)の先頭と一致していた割合 → 高いほど「後で取り消されない」
  表示率         : 末尾 m 文字を隠した結果、訳全体のうち実際に表示されている割合
  m              : Mask-k に相当する「末尾から隠す文字数」
"""
import json, sys, statistics as st
from collections import defaultdict


def common_prefix_len(a, b):
    n = 0
    for x, y in zip(a, b):
        if x != y:
            break
        n += 1
    return n


def main(path, example=None):
    data = json.load(open(path, encoding="utf-8"))
    by = defaultdict(lambda: defaultdict(list))
    for r in data:
        by[r["strategy"]][r["si"]].append(r)
    for s in by.values():
        for seq in s.values():
            seq.sort(key=lambda r: r["k"])

    for strat, sents in by.items():
        ms = [r["ms"] for seq in sents.values() for r in seq]
        print("=" * 70)
        print(strat)
        print("呼び出し %d 回  時間 中央値 %d ms / 90%%点 %d ms / 最大 %d ms" % (
            len(ms), st.median(ms), sorted(ms)[int(len(ms) * 0.9) - 1], max(ms)))
        print("\n%4s %12s %12s %10s" % ("m", "書き換わりNE", "先頭一致率", "表示率"))
        for m in (0, 3, 6, 9, 12, 16, 20):
            erased = total_final = ok = steps = 0
            shown = []
            for seq in sents.values():
                final = seq[-1]["ja"]
                prev = ""
                for r in seq:
                    ja = r["ja"]
                    disp = ja[:max(0, len(ja) - m)]
                    erased += len(prev) - common_prefix_len(prev, disp)
                    prev = disp
                    steps += 1
                    ok += 1 if final.startswith(disp) else 0
                    shown.append(len(disp) / max(len(ja), 1))
                total_final += len(final)
            print("%4d %12.2f %11.0f%% %9.0f%%" % (m, erased / total_final, 100 * ok / steps, 100 * st.mean(shown)))

        if example is not None and example in sents:
            print("\n-- 例: 文 %d (%s) --" % (example, strat))
            for r in sents[example]:
                print("%2d語 %4dms | %s => %s" % (r["k"], r["ms"], r["en"][-40:], r["ja"]))


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(__doc__); sys.exit(2)
    main(sys.argv[1], int(sys.argv[2]) if len(sys.argv) > 2 else None)
