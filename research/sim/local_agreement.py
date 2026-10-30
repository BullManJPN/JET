#!/usr/bin/env python3
"""単語単位の LocalAgreement: 連続 K 回の到着の塊で共通する先頭部分を確定(後戻りしない)。
評価: 確定語のうち ASR最終結果と食い違った割合 / 確定の遅れ(話された時刻→確定まで、推定) / 確定後に節で切った塊の長さ
使い方: python3 sim/local_agreement.py [K]"""
import json, re, sys, glob, statistics as st
K = int(sys.argv[1]) if len(sys.argv) > 1 else 2
W = lambda t: re.findall(r"[\w'’-]+[.,?!]?", t)
N = lambda w: re.sub(r"[^\w']", "", w.lower())
tot = bad = 0; diffs = []; lags = []; finals_lag = []
for f in sorted(glob.glob("logs/asr-20261028-*-mic.jsonl")):
    ev = [json.loads(l) for l in open(f) if l.strip()]
    ev = [e for e in ev if e.get("kind") in ("volatile", "final")]
    seg = []
    for e in ev:
        if e["kind"] == "volatile":
            if seg and e["wall"] - seg[-1]["wall"] < 0.3: seg[-1] = e
            else: seg.append(e)
            continue
        fw = W(e["text"]); dur = e["audio_end"] - e["audio_start"]
        committed = []; ctime = []
        for i in range(K - 1, len(seg)):
            ws = [W(seg[j]["text"]) for j in range(i - K + 1, i + 1)]
            n = 0
            while all(len(w) > n for w in ws) and len({N(w[n]) for w in ws}) == 1: n += 1
            if n > len(committed):
                new = ws[-1][len(committed):n]
                committed += new; ctime += [seg[i]["wall"]] * len(new)
        # 確定しなかった残りは ASR final で確定
        import difflib
        a=[N(w) for w in committed]; b=[N(w) for w in fw[:len(committed)+3]]
        sm=difflib.SequenceMatcher(None,a,b,autojunk=False)
        eq=sum(x.size for x in sm.get_matching_blocks())
        tot += len(a); bad += len(a)-eq
        if len(a)-eq>0: diffs.append((" ".join(committed), e["text"].strip()))
        for k, w in enumerate(committed):
            # 話された時刻の推定(区間内で均等)
            spoken = e["audio_start"] + (k + 1) / max(1, len(fw)) * dur
            lags.append(ctime[k] - spoken)
        for k in range(len(committed), len(fw)):
            spoken = e["audio_start"] + (k + 1) / max(1, len(fw)) * dur
            finals_lag.append(e["wall"] - spoken)
        seg = []
allw = len(lags) + len(finals_lag)
print("K=%d 全 %d 語: 仮テキストで先に確定 %d 語 (%.0f%%), ASR確定まで待った語 %d" % (K, allw, len(lags), 100*len(lags)/allw, len(finals_lag)))
print("  先に確定した語のうち最終結果と食い違い: %d (%.1f%%)" % (bad, 100*bad/max(1,tot)))
print("  確定の遅れ(推定・話してから): 先行確定 中央値 %.1fs p90 %.1fs / ASR確定待ち 中央値 %.1fs p90 %.1fs" % (
    st.median(lags), sorted(lags)[int(len(lags)*.9)], st.median(finals_lag), sorted(finals_lag)[int(len(finals_lag)*.9)]))

if "-v" in sys.argv:
    for c,f in diffs: print("  仮:",c,"\n  確:",f,"\n")
