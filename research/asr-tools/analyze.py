#!/usr/bin/env python3
"""asrlog の JSONL を集計する。使い方: python3 asr/analyze.py logs/asr-xxxx.jsonl

指標:
  確定の遅れ   : 区間の最後の単語が話し終わってから、確定結果が届くまで(秒)  ※final は単語時刻つき
  到着の塊     : 同時刻(0.3秒以内)に届いた結果のまとまり。間隔が一定=一括配信
  NE           : 途中結果の更新で消えた語数 / 確定語数 (小さいほど安定)
  鮮度(推定)   : 途中表示の最新単語が話されてから、画面に届くまで。
                 volatile には単語時刻がないため、確定区間内で単語が均等に話されたと仮定した推定値
"""
import json, sys, statistics as st, re


def words(t):
    return re.findall(r"[\w'’-]+", t)


def common_prefix(a, b):
    n = 0
    for x, y in zip(a, b):
        if x.lower() != y.lower():
            break
        n += 1
    return n


def bursts(evs):
    out = []
    for e in evs:
        if out and e["wall"] - out[-1][-1]["wall"] < 0.3:
            out[-1].append(e)
        else:
            out.append([e])
    return out


def main(path):
    ev = [json.loads(l) for l in open(path, encoding="utf-8") if l.strip()]
    meta = next((e for e in ev if e.get("kind") == "meta"), {})
    ev = [e for e in ev if e.get("kind") in ("volatile", "final")]

    segs, cur = [], []
    for e in ev:
        cur.append(e)
        if e["kind"] == "final":
            segs.append(cur)
            cur = []
    if cur:
        segs.append(cur)

    rows, fresh = [], []
    total_erase = total_final_words = 0
    for s in segs:
        vols = [e for e in s if e["kind"] == "volatile"]
        fin = [e for e in s if e["kind"] == "final"]
        f = fin[-1] if fin else None
        erase, prev = 0, []
        for v in vols:
            w = words(v["text"])
            erase += max(0, len(prev) - common_prefix(prev, w))
            prev = w
        fw = words(f["text"]) if f else prev
        if f:
            erase += max(0, len(prev) - common_prefix(prev, fw))
        total_erase += erase
        total_final_words += len(fw)

        # 鮮度(推定): 塊ごとに、最後の途中結果の最新単語の推定時刻と、届いた時点の投入量の差
        if f and len(fw) > 0 and "fed" in f:
            for blk in bursts(vols):
                last = blk[-1]
                k = min(len(words(last["text"])), len(fw))
                est_end = f["audio_start"] + (k / len(fw)) * (f["audio_end"] - f["audio_start"])
                fresh.append(last["fed"] - est_end)

        rows.append({
            "text": f["text"].strip() if f else "(未確定) " + (vols[-1]["text"].strip() if vols else ""),
            "words": len(fw), "updates": len(vols),
            "dur": (f["audio_end"] - f["audio_start"]) if f else None,
            "final_lag": f["lag"] if f else None,
            "erasure": erase, "punct": bool(f and re.search(r"[.,?!]", f["text"])),
            "final": bool(f),
        })

    print("設定:", {k: meta.get(k) for k in ("preset", "fast", "prepare", "chunk_ms")}, " 入力:", meta.get("source"))
    print("== 区間ごと ==")
    print("%3s %5s %8s %8s %9s %6s  %s" % ("#", "語数", "区間(秒)", "更新回数", "確定の遅れ", "消去語", "確定テキスト"))
    for i, r in enumerate(rows, 1):
        fm = lambda x: "-" if x is None else "%.2f" % x
        print("%3d %5d %8s %8d %9s %6d  %s" % (i, r["words"], fm(r["dur"]), r["updates"], fm(r["final_lag"]),
                                               r["erasure"], r["text"][:60]))

    fl = [r["final_lag"] for r in rows if r["final_lag"] is not None]
    b = bursts(ev)
    print("\n== 要約 ==")
    print("確定した区間: %d / 全区間 %d   (1区間の長さ 平均 %.1f秒 / 最長 %.1f秒)" % (
        len(fl), len(rows),
        st.mean(r["dur"] for r in rows if r["dur"]) if any(r["dur"] for r in rows) else 0,
        max((r["dur"] for r in rows if r["dur"]), default=0)))
    if fl:
        print("確定の遅れ(最後の単語から)  中央値 %.2fs  最大 %.2fs" % (st.median(fl), max(fl)))
    if fresh:
        print("途中表示の鮮度(推定)        中央値 %.2fs  最大 %.2fs" % (st.median(fresh), max(fresh)))
    if total_final_words:
        print("NE(消去語/確定語)          %.2f" % (total_erase / total_final_words))
    if len(b) > 1:
        gaps = [b[i][0]["wall"] - b[i - 1][0]["wall"] for i in range(1, len(b))]
        print("結果の到着: %d 回の塊、間隔 中央値 %.2fs / 1塊あたり %.1f 件" % (
            len(b), st.median(gaps), st.mean(len(x) for x in b)))
    nf = sum(1 for r in rows if r["final"])
    print("句読点つき確定: %d / %d" % (sum(1 for r in rows if r["punct"] and r["final"]), nf))


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print(__doc__); sys.exit(2)
    main(sys.argv[1])
