#!/usr/bin/env python3
"""節の閉じ方の検討用。engine_mirror の Engine を継承して、節が閉じた理由(句読点 / 接続詞 / 長さ上限 / ASR確定)を記録し、設定の違いを比べる。
指標は話し終えた推定時刻(区間内の均等割り)からの遅れなので、絶対値は±0.5秒程度。比較に使う。
使い方(リポジトリのルートで): python3 sim/clause_study.py"""
import json, sys, os, glob, statistics as st
H = os.path.dirname(os.path.abspath(__file__)); ROOT = os.path.dirname(H)
sys.path.insert(0, H)
import core, engine_mirror as M
from core import W, N
import correct_terms
T, A = correct_terms.load(os.path.join(ROOT, "asr/terms.txt"), os.path.join(ROOT, "asr/term_aliases.tsv"))
multi = [[N(t) for t in x.split()] for x, _ in A if len(x.split()) > 1]
FILES = sorted(glob.glob(os.path.join(ROOT, "logs/asr-20261028-*-mic.jsonl"))) + [os.path.join(ROOT, "logs/asr-20261028-154426-live.jsonl")]
BASE_CONJ = set(core.CONJ)
q = lambda x, p: sorted(x)[min(len(x) - 1, int(len(x) * p))]


class E2(M.Engine):
    def __init__(s, *a):
        super().__init__(*a); s.reason = "flush"; s.log = []
    def feed(s, w, k):
        if s.cur and N(w) in M.CONJ and len(s.cur) >= s.cfg.min_clause:
            s.reason = "conj"; s.close(); s.reason = "flush"
        s.cur.append((w, k))
        ends = bool(w) and w[-1] in ",;.?!"
        if ends and len(s.cur) >= s.cfg.min_clause:
            s.reason = "punct"; s.close(); s.reason = "flush"
        elif len(s.cur) >= s.cfg.max_clause:
            s.reason = "max"; s.close(); s.reason = "flush"
    def close(s):
        s.log.append(dict(k1=s.cur[-1][1], n=len(s.cur), reason=s.reason, t=s.stamp))
        super().close()


def run(K=2, mn=4, mx=14, conj=None):
    M.C.K, M.C.min_clause, M.C.max_clause, M.C.hold_last, M.C.coalesce_s = K, mn, mx, 0, 0.1
    M.CONJ = set(conj if conj is not None else BASE_CONJ)
    R = dict(n=0, words=0, short=0, lag=[], first=[], stale=0, rlag={}, rn={})
    for p in FILES:
        eng = E2(M.C, T, A, multi, p); cur = []
        for l in open(p):
            if not l.strip(): continue
            e = json.loads(l); k = e.get("kind")
            if k == "volatile": cur += eng.volatile(e["text"], e["wall"])
            elif k == "final":
                r = eng.finalize(e["text"], e["wall"]); cur += r
                fw = W(M.correct_terms.correct(e["text"], T, A)); nfw = max(len(fw), 1)
                a0 = e["audio_start"]; dur = e["audio_end"] - a0
                sp = lambda kk: a0 + min(kk + 1, nfw) / nfw * dur
                R["stale"] += sum(1 for x in cur if x["kind"] == "clause_stale")
                for c in eng.log:
                    lag = c["t"] - sp(c["k1"])
                    R["n"] += 1; R["words"] += c["n"]; R["short"] += c["n"] <= 3; R["lag"].append(lag)
                    R["rlag"].setdefault(c["reason"], []).append(lag); R["rn"][c["reason"]] = R["rn"].get(c["reason"], 0) + 1
                if eng.log: R["first"].append(min(c["t"] for c in eng.log) - a0)
                eng.log = []; cur = []
    return R


def row(name, R):
    print("%-34s 節%4d 平均%4.1f語 3語以下%3.0f%% | 閉じるまで 中央値%5.2f p90%5.2f | 区間の最初の節 中央値%5.2f | 古い下書き%4.1f%%" % (
        name, R["n"], R["words"] / R["n"], 100 * R["short"] / R["n"], st.median(R["lag"]), q(R["lag"], .9), st.median(R["first"]), 100 * R["stale"] / R["n"]))


b = run()
print("== 閉じた理由(現行 K=2 最小4語 最大14語)")
for r in ["punct", "conj", "max", "flush"]:
    if r in b["rn"]:
        print("  %-5s %3d 節 (%2.0f%%)  閉じるまでの遅れ 中央値 %5.2f / p90 %5.2f s" % (r, b["rn"][r], 100 * b["rn"][r] / b["n"], st.median(b["rlag"][r]), q(b["rlag"][r], .9)))
print("\n== 設定の比較(7本・遅れは話し終えた推定時刻から。コミット待ち込み・まとめ待ち100msは未加算)")
row("現行 (K2, 最小4, 最大14)", b)
more = BASE_CONJ | {"so", "then", "that", "since", "though", "before", "after", "until", "unless", "whether", "as"}
row("接続詞を増やす(so, then, that, ...)", run(conj=more))
row("so だけ追加", run(conj=BASE_CONJ | {"so"}))
row("最大 10 語", run(mx=10))
row("最大 8 語", run(mx=8))
row("最小 3 語", run(mn=3))
row("最小 3 + 最大 10 + 接続詞増", run(mn=3, mx=10, conj=more))
row("K=1(参考: 速いが不安定)", run(K=1))
row("K=1 + 最大 10", run(K=1, mx=10))
