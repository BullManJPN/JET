#!/usr/bin/env python3
"""節の区切り方の案を比べる(10/29)。core.process_segment の確定(LocalAgreement + 用語補正 + 辞書にない語の3秒待ち)はそのまま、
節の閉じ方(feed)だけを案ごとに差し替える。
出力: 表(節の数・長さ・断片の割合・節が閉じる遅れ)と、AFM ベンチ用の節セット results/clause-set-<案>.jsonl(id = 録音|区間|節)
使い方(リポジトリのルートで): python3 sim/clause_rules.py"""
import json, os, re, sys, statistics as st
H = os.path.dirname(os.path.abspath(__file__)); ROOT = os.path.dirname(H)
sys.path.insert(0, H); os.chdir(ROOT)
import core
from core import W, N

LOGS = [("rec1", "asr-20261029-122827-live"), ("rec2", "asr-20261029-121252-live"), ("rec3", "asr-20261029-120310-live"),
        ("rec4", "asr-20261029-112432-live"), ("rec5", "asr-20261029-151107-live"), ("rec6", "asr-20261029-154629-live")]
SUBJ = set("i you we they he she it this that there the a an my our your their his her its so then now these those some many most all people everyone you're we're they're it's i'm there's that's".split())
DANGLING = set("a an the to of for with from in on at by into about and or but which that who your their our my its his her is are was were be been can could will would should have has had do does not very more most so than as if when while".split())
VARIANTS = {
    "v0": dict(desc="今(and/or/which 等で閉じる、14語で切る)", close=core.CONJ, look=set(), max=14, smart=False),
    "v1": dict(desc="and/or は次の語が主語らしいときだけ閉じる", close=core.CONJ - {"and", "or"}, look={"and", "or"}, max=14, smart=False),
    "v2": dict(desc="v1 + which/where では閉じない", close=core.CONJ - {"and", "or", "which", "where"}, look={"and", "or"}, max=14, smart=False),
    "v3": dict(desc="v2 + 上限で切るとき前置詞・冠詞などの後では切らない", close=core.CONJ - {"and", "or", "which", "where"}, look={"and", "or"}, max=14, smart=True),
    "v4": dict(desc="v3 + 上限 18語", close=core.CONJ - {"and", "or", "which", "where"}, look={"and", "or"}, max=18, smart=True),
}
PRON = set("i you we they he she it this there you're we're they're it's i'm there's that's".split())
VARIANTS["v5"] = dict(VARIANTS["v4"], desc="v4 + and の後は代名詞のときだけ閉じる(the/their などでは閉じない)", subj=PRON)
VARIANTS["v6"] = dict(VARIANTS["v5"], desc="v5 + 18語を超えても3語までは句読点を待つ", soft=3)
VARIANTS["v4s"] = dict(VARIANTS["v4"], desc="v4 + 18語を超えても3語までは句読点を待つ", soft=3)


def load_segments(path, coalesce=0.1):
    segs, cur = [], []
    for l in open(path):
        if not l.strip(): continue
        e = json.loads(l); k = e.get("kind")
        if k == "volatile":
            if cur and e["wall"] - cur[-1]["wall"] < coalesce: cur[-1] = e
            else: cur.append(e)
        elif k == "final":
            segs.append((cur, e)); cur = []
    return segs


def run(batches, fin, cfg, T, A, multi, V, known, var):
    corr = lambda s: core.correct_terms.correct(s, T, A)
    fin_raw = W(fin["text"]); fw = W(corr(fin["text"])); nfw = max(len(fw), 1)
    a0 = fin["audio_start"]; dur = fin["audio_end"] - a0
    spoken = lambda k: a0 + min(k + 1, nfw) / nfw * dur
    raw, emitted, clauses, cur = [], [], [], []
    st_ = dict(look=False)

    def close(t, upto=None):
        part = cur[:upto] if upto is not None else list(cur)
        if not part: return
        ks = [k for _, k in part]
        clauses.append(dict(text=" ".join(w for w, _ in part), n=len(part), t_close=t, spoken_end=spoken(ks[-1])))
        del cur[:len(part)]

    def feed(w, k, t):
        n = N(w)
        if st_["look"]:
            st_["look"] = False
            if n in var.get("subj", SUBJ) and len(cur) - 1 >= cfg.min_clause: close(t, len(cur) - 1)
        if cur and n in var["close"] and len(cur) >= cfg.min_clause: close(t)
        cur.append((w, k))
        if re.search(r"[,;.?!]$", w) and len(cur) >= cfg.min_clause: close(t); return
        if n in var["look"] and not re.search(r"[,;.?!]$", w): st_["look"] = True
        if len(cur) >= var["max"] + var.get("soft", 0):
            if var["smart"]:
                i = len(cur)
                while i > cfg.min_clause and N(cur[i - 1][0]) in DANGLING: i -= 1
                if N(cur[i - 1][0]) not in DANGLING:
                    st_["look"] = False; close(t, i); return
            st_["look"] = False; close(t)

    def commit(t, flush):
        held = 0 if flush else core.held_count(raw, multi)
        c = W(corr(" ".join(raw[:len(raw) - held])))
        if len(c) < len(emitted): return
        for w in c[len(emitted):]:
            k = len(emitted); emitted.append(w); feed(w, k, t)

    hist, since = [], {}
    for b in batches:
        hist.append(W(b["text"]))
        if len(hist) >= cfg.K:
            ws = hist[-cfg.K:]; n = 0
            while all(len(x) > n for x in ws) and len({N(x[n]) for x in ws}) == 1: n += 1
            if n == len(ws[-1]): n = max(n - cfg.hold_last, 0)
            n = core.hold_cut(ws[-1], len(raw), n, b["wall"], since, cfg.hold_unknown, V, known)
            if n > len(raw):
                raw.extend(ws[-1][len(raw):n]); commit(b["wall"], False)
    raw.extend(fin_raw[len(raw):]); commit(fin["wall"], True)
    st_["look"] = False
    if cur: close(fin["wall"])
    return clauses


def fragment(c):
    ws = c["text"].split(); last = ws[-1]
    if re.search(r"[.?!]$", last): return False
    return N(last) in DANGLING or len(ws) <= 3


def main():
    cj = json.load(open("jet.json"))
    cfg = core.Cfg(K=cj["K"], hold_last=cj["hold_last"], min_clause=cj["min_clause"], max_clause=cj["max_clause"],
                   early_after=cj["early_after"], hold_unknown=cj.get("hold_unknown_s", 0))
    T, A, multi = core.load_terms(); V = core.load_vocab(); known = core.known_words(T, A)
    q = lambda x, p: sorted(x)[min(len(x) - 1, int(len(x) * p))]
    print("| 案 | 内容 | 節 | 平均語数 | 断片 | 前置詞・冠詞などで終わる | 節が閉じる遅れ 中央値 | p90 | 間のあと続けて出る | 3語以下の文末 |")
    print("|---|---|---|---|---|---|---|---|---|---|")
    for vn, var in VARIANTS.items():
        C, out = [], []
        for name, log in LOGS:
            for si, (bt, fin) in enumerate(load_segments(f"logs/{log}.jsonl")):
                if not fin["text"].strip(): continue
                cl = run(bt, fin, cfg, T, A, multi, V, known, var)
                for ci, c in enumerate(cl):
                    out.append(dict(id=f"{name}|{si}|{ci}", src=name, en=c["text"]))
                C += cl
        fr = sum(fragment(c) for c in C); dg = sum(N(c["text"].split()[-1]) in DANGLING and not re.search(r"[.?!,]$", c["text"]) for c in C)
        d = [c["t_close"] - c["spoken_end"] for c in C]
        bursts = sum(1 for i in range(1, len(C) - 1) if C[i]["t_close"] - C[i-1]["t_close"] >= 3 and 0 <= C[i+1]["t_close"] - C[i]["t_close"] <= 1)
        tails = sum(1 for c in C if c["n"] <= 3 and re.search(r"[.?!]$", c["text"]))
        print(f"| {vn} | {var['desc']} | {len(C)} | {st.mean(c['n'] for c in C):.1f} | {fr} ({fr/len(C)*100:.1f}%) | {dg} ({dg/len(C)*100:.1f}%) | {st.median(d):.2f}秒 | {q(d,.9):.2f}秒 | {bursts} | {tails} |")
        with open(f"results/clause-set-{vn}.jsonl", "w") as f:
            for o in out: f.write(json.dumps(o, ensure_ascii=False) + "\n")


if __name__ == "__main__":
    main()
