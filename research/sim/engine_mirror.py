#!/usr/bin/env python3
"""jet/Core.swift の Engine を、構造をそのまま保って Python に写したもの(逐次処理版)。
Swift をビルドする前に、逐次化した論理(まとめ・確定・節・先出し・最終訳の英語・古い下書き)が sim/core.py と一致するか確かめるために使う。
使い方(リポジトリのルートで): python3 sim/engine_mirror.py [--out results/mirror-events.jsonl]  →  python3 sim/parity.py results/mirror-events.jsonl"""
import sys, os, re, json, glob, difflib, argparse
H = os.path.dirname(os.path.abspath(__file__)); ROOT = os.path.dirname(H)
sys.path.insert(0, H)
import core
from core import W, N, CONJ
import correct_terms


class Engine:
    def __init__(s, cfg, T, A, multi, file):
        s.cfg, s.T, s.A, s.multi, s.file = cfg, T, A, multi, file
        s.seg = 0; s.pend = None; s.evs = []; s.stamp = 0.0; s.reset()

    def reset(s):
        s.raw, s.emitted, s.hist, s.clauses, s.units, s.unsent, s.cur = [], [], [], [], [], [], []
        s.unit_start = None; s.last_k1 = -1; s.unstable = 0; s.since = {}; s.look = False

    def corr(s, t): return correct_terms.correct(t, s.T, s.A)
    def ev(s, kind, **kw): return dict(kind=kind, t=s.stamp, file=s.file, seg=s.seg, **kw)
    def take(s): r, s.evs = s.evs, []; return r

    def volatile(s, text, wall):
        if s.pend is not None:
            p = s.pend
            if wall - p[1] < s.cfg.coalesce_s:
                s.pend = (text, wall); return []
            s.pend = (text, wall)
            s.process_batch(p[0], p[1], p[1]); return s.take()
        s.pend = (text, wall); return []

    def finalize(s, text, wall):
        s.stamp = wall
        if not text.strip():
            s.pend = None; s.evs = []; s.reset(); s.seg += 1; return []
        if s.pend is not None:
            p, s.pend = s.pend, None
            s.process_batch(p[0], p[1], p[1])
        s.stamp = wall
        fin_raw = W(text)
        fw = W(s.corr(text) if s.cfg.correct else text)
        n_la = len(s.emitted)
        if len(fin_raw) > len(s.raw): s.raw.extend(fin_raw[len(s.raw):])
        s.commit(wall, True)
        if s.cur: s.close()
        if s.unsent: s.send(wall, False, fw)
        a = [N(w) for w in s.emitted[:n_la]]; b = [N(w) for w in fw[:n_la + 3]]
        ok = set()
        for blk in difflib.SequenceMatcher(None, a, b, autojunk=False).get_matching_blocks():
            ok.update(range(blk.a, blk.a + blk.size))
        bad = {k for k in range(len(a)) if k not in ok}
        stale = [s.ev("clause_stale", idx=c["idx"]) for c in s.clauses if any(k in bad for k in range(c["k0"], c["k1"] + 1))]
        res = [s.ev("seg", text=text.strip())] + s.take() + stale
        s.seg += 1; s.reset(); return res

    def process_batch(s, text, wall, stamp):
        s.stamp = stamp
        if s.unit_start is None: s.unit_start = wall
        s.hist.append(W(text))
        if len(s.hist) >= s.cfg.K:
            ws = s.hist[-s.cfg.K:]
            n = 0
            while all(len(w) > n for w in ws) and len({N(w[n]) for w in ws}) == 1: n += 1
            last = ws[-1]
            if n == len(last): n = max(n - s.cfg.hold_last, 0)
            if s.cfg.hold_unknown > 0:
                n = core.hold_cut(last, len(s.raw), n, wall, s.since, s.cfg.hold_unknown, core.load_vocab(), core.known_words(s.T, s.A))
            if n > len(s.raw):
                s.raw.extend(last[len(s.raw):n]); s.commit(wall, False)
        if s.unsent and s.unit_start is not None and wall - s.unit_start >= s.cfg.early_after:
            s.send(wall, True, [])

    def held_count(s):
        best = 0
        for toks in s.multi:
            sz = min(len(toks) - 1, len(s.raw))
            while sz > 0:
                if [N(w) for w in s.raw[-sz:]] == toks[:sz]: best = max(best, sz); break
                sz -= 1
        return best

    def commit(s, t, flush):
        held = 0 if (flush or not s.cfg.correct) else s.held_count()
        part = s.raw[:len(s.raw) - held]
        c = W(s.corr(" ".join(part))) if s.cfg.correct else list(part)
        if len(c) < len(s.emitted): s.unstable += 1; return
        words = []
        for w in c[len(s.emitted):]:
            k = len(s.emitted); s.emitted.append(w); words.append(w); s.feed(w, k)
        if words: s.evs.append(s.ev("commit", words=words, flush=flush))

    def feed(s, w, k):
        n = N(w)
        if s.look:
            s.look = False
            if n in s.cfg.look_subj and len(s.cur) - 1 >= s.cfg.min_clause: s.close(len(s.cur) - 1)
        if s.cur and n in core.close_conj(s.cfg) and len(s.cur) >= s.cfg.min_clause: s.close()
        s.cur.append((w, k))
        ends = bool(w) and w[-1] in ",;.?!"
        if ends and len(s.cur) >= s.cfg.min_clause: s.close(); return
        if n in s.cfg.look_conj and not ends: s.look = True
        if len(s.cur) >= s.cfg.max_clause + s.cfg.soft_max:
            s.look = False
            if s.cfg.smart_max:
                i = len(s.cur)
                while i > s.cfg.min_clause and N(s.cur[i - 1][0]) in core.DANGLING: i -= 1
                if N(s.cur[i - 1][0]) not in core.DANGLING: s.close(i); return
            s.close()

    def close(s, upto=None):
        part = s.cur[:upto] if upto is not None else list(s.cur)
        c = dict(idx=len(s.clauses), text=" ".join(w for w, _ in part), n=len(part), k0=part[0][1], k1=part[-1][1], unit=None)
        s.clauses.append(c); s.unsent.append(c["idx"]); s.cur = s.cur[len(part):]
        s.evs.append(s.ev("clause", idx=c["idx"], text=c["text"]))

    def aligned_next(s, k, fw):
        a = [N(w) for w in s.emitted]; b = [N(w) for w in fw]; mp = {}
        for blk in difflib.SequenceMatcher(None, a, b, autojunk=False).get_matching_blocks():
            for x in range(blk.size): mp[blk.a + x] = blk.b + x
        j = k
        while j >= 0 and j not in mp: j -= 1
        return mp[j] + 1 if j >= 0 else 0

    def send(s, t, early, fw):
        k0 = s.clauses[s.unsent[0]]["k0"]; k1 = s.clauses[s.unsent[-1]]["k1"]
        ks = s.aligned_next(s.last_k1, fw) if (not early and s.last_k1 >= 0) else 0
        words = s.emitted[k0:k1 + 1] if early else (fw[ks:] if ks < len(fw) else [])
        n_words = sum(s.clauses[i]["n"] for i in s.unsent)
        ui = len(s.units)
        for i in s.unsent: s.clauses[i]["unit"] = ui
        s.units.append(dict(clauses=list(s.unsent), n_words=n_words, early=early))
        s.evs.append(s.ev("final_req", unit=ui, early=early, n_clauses=len(s.unsent), n_words=n_words,
                          en=" ".join(words).strip(), clauses=list(s.unsent)))
        s.unsent = []; s.unit_start = t; s.last_k1 = k1




if __name__ == "__main__":
    ap = argparse.ArgumentParser(); ap.add_argument("--out", default="results/mirror-events.jsonl")
    ap.add_argument("--hold-last", type=int); ap.add_argument("--hold-unknown", type=float)
    ap.add_argument("--config", help="jet.json の確定・節の設定を使う(なしなら従来の既定値)")
    ap.add_argument("--files", nargs="*"); a = ap.parse_args()
    if a.config:
        C = core.load_cfg(a.config, hold_last=a.hold_last, hold_unknown=a.hold_unknown)
    else:
        C = core.Cfg(hold_last=0 if a.hold_last is None else a.hold_last, hold_unknown=a.hold_unknown or 0.0)
    C.coalesce_s = 0.3
    T, A = correct_terms.load(os.path.join(ROOT, "asr/terms.txt"), os.path.join(ROOT, "asr/term_aliases.tsv"))
    multi = [[N(t) for t in x.split()] for x, _ in A if len(x.split()) > 1]
    out = []
    paths = []
    for pat in (a.files or ["logs/asr-20261028-*-mic.jsonl"]): paths += sorted(glob.glob(os.path.join(ROOT, pat)))
    for p in paths:
        name = os.path.basename(p).replace("asr-", "").replace(".jsonl", "")
        eng = Engine(C, T, A, multi, name)
        for l in open(p):
            if not l.strip(): continue
            e = json.loads(l); k = e.get("kind")
            if k == "volatile": out += eng.volatile(e["text"], e["wall"])
            elif k == "final": out += eng.finalize(e["text"], e["wall"])
    with open(os.path.join(ROOT, a.out), "w") as f:
        for e in out: f.write(json.dumps(e, ensure_ascii=False) + "\n")
    print(a.out, len(out), "イベント")
