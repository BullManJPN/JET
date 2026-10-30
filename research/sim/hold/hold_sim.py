"""使い方: cd <リポジトリのルート> && python3 sim/hold/hold_sim.py   (辞書 vocab.txt は build_vocab.py で Hunspell en_US から作った。10/29)
辞書にない語の確定を、最終結果まで(最長 max_hold 秒)待つ案のシミュレーション。
core.process_segment の LocalAgreement 部分だけを差し替えて、4本の録音で比べる。"""
import json, re, sys, os, statistics as st, difflib
HERE = os.path.dirname(os.path.abspath(__file__)); ROOT = os.path.dirname(os.path.dirname(HERE)); os.chdir(ROOT); sys.path.insert(0, 'sim')
import core
from core import W, N, CONJ

V = set(open(os.path.join(HERE, '..', '..', '..', 'asr', 'vocab.txt')).read().split())
T, A, MULTI = core.load_terms()
KNOWN = {N(t) for t in T for t in t.split()} | {N(c) for _, c in A for c in c.split()}

def suspicious(w, mode):
    n = N(w)
    if not n or n.isdigit() or re.fullmatch(r"\d+(st|nd|rd|th|s)?", n): return False
    if n in V or n in KNOWN: return False
    if "'" in n and n.split("'")[0] in V: return False
    if mode == "lower" and w[:1].isupper(): return False   # 大文字で始まる語(固有名詞らしい)は待たない
    return True

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

def run_segment(batches, fin, cfg, mode, max_hold):
    # core.process_segment の写し。違いは「合意した先頭」に待つべき語があればそこで止めること
    corr = (lambda s: core.correct_terms.correct(s, T, A))
    fin_raw = W(fin["text"]); fw = W(corr(fin["text"])); nfw = max(len(fw), 1)
    a0 = fin["audio_start"]; dur = fin["audio_end"] - a0
    spoken = lambda k: a0 + min(k + 1, nfw) / nfw * dur
    raw, emitted, etime, clauses, cur = [], [], [], [], []
    held_since = {}
    def close(t):
        ks = [k for _, k in cur]
        clauses.append(dict(text=" ".join(w for w, _ in cur), k0=ks[0], k1=ks[-1], t_close=t, spoken_end=spoken(ks[-1])))
        cur.clear()
    def feed(w, k, t):
        if cur and N(w) in CONJ and len(cur) >= cfg.min_clause: close(t)
        cur.append((w, k))
        if (re.search(r"[,;.?!]$", w) and len(cur) >= cfg.min_clause) or len(cur) >= cfg.max_clause: close(t)
    def commit(t, flush):
        held = 0 if flush else core.held_count(raw, MULTI)
        c = W(corr(" ".join(raw[:len(raw) - held])))
        if len(c) < len(emitted): return
        for w in c[len(emitted):]:
            k = len(emitted); emitted.append(w); etime.append(t); feed(w, k, t)
    hist = []; nholds = 0
    for b in batches:
        hist.append(W(b["text"]))
        if len(hist) >= cfg.K:
            ws = hist[-cfg.K:]; n = 0
            while all(len(w) > n for w in ws) and len({N(w[n]) for w in ws}) == 1: n += 1
            if n == len(ws[-1]): n = max(n - cfg.hold_last, 0)
            if mode != "off":
                for j in range(len(raw), n):
                    w = ws[-1][j]
                    if suspicious(w, mode):
                        key = (j, N(w)); t0 = held_since.setdefault(key, b["wall"])
                        if b["wall"] - t0 < max_hold:
                            n = j; nholds += 1; break
            if n > len(raw):
                raw.extend(ws[-1][len(raw):n]); commit(b["wall"], False)
    n_la = len(emitted)
    raw.extend(fin_raw[len(raw):]); commit(fin["wall"], True)
    if cur: close(fin["wall"])
    a = [N(w) for w in emitted[:n_la]]; bb = [N(w) for w in fw[:n_la + 3]]
    ok = set()
    for blk in difflib.SequenceMatcher(None, a, bb, autojunk=False).get_matching_blocks(): ok.update(range(blk.a, blk.a + blk.size))
    bad = {k for k in range(len(a)) if k not in ok}
    fset = {N(w) for w in fw}
    for c in clauses:
        c["stale"] = any(k in bad for k in range(c["k0"], c["k1"] + 1))
        c["garbled"] = any(N(w) not in fset for w in W(c["text"]))
    delays = [etime[k] - spoken(k) for k in range(n_la)]
    return clauses, delays

cfgj = json.load(open('jet.json'))
cfg = core.Cfg(K=cfgj["K"], hold_last=cfgj["hold_last"], min_clause=cfgj["min_clause"], max_clause=cfgj["max_clause"], early_after=cfgj["early_after"])
LOGS = [("mlx", "asr-20261029-122827-live"), ("talk1", "asr-20261029-121252-live"), ("pair", "asr-20261029-120310-live"), ("yt", "asr-20261029-112432-live")]
def pct(a, p): a = sorted(a); return a[min(len(a)-1, int(len(a)*p))] if a else 0

print("| 案 | 節 | 英語が最終と食い違う節 | 崩れた語を含む節 | 語の確定の遅れ 中央値 | p90 | 節が閉じる遅れ 中央値 | p90 |")
print("|---|---|---|---|---|---|---|---|")
for label, mode, mh in [("今(待たない)", "off", 0), ("辞書にない語は待つ 最長1秒", "all", 1.0), ("最長2秒", "all", 2.0), ("最長3秒", "all", 3.0), ("最長5秒", "all", 5.0), ("最終結果まで", "all", 99.0), ("小文字の語だけ待つ 最長2秒", "lower", 2.0), ("同 最長3秒", "lower", 3.0)]:
    C, D, CL = [], [], []
    for name, log in LOGS:
        for bt, fin in load_segments(f"logs/{log}.jsonl"):
            cl, d = run_segment(bt, fin, cfg, mode, mh); C += cl; D += d
    n = len(C); stale = sum(c["stale"] for c in C); gar = sum(c["garbled"] for c in C)
    cd = [c["t_close"] - c["spoken_end"] for c in C]
    print(f"| {label} | {n} | {stale} ({stale/n*100:.1f}%) | {gar} ({gar/n*100:.1f}%) | {st.median(D):.2f}s | {pct(D,.9):.2f}s | {st.median(cd):.2f}s | {pct(cd,.9):.2f}s |")
