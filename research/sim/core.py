#!/usr/bin/env python3
"""JETシミュレーターの部品。ログの volatile/final を wall 順に再生し、各語が「いつ確定したか」を再現する(訳そのものは呼ばない)。
 1) 単語単位 LocalAgreement(K回連続一致の先頭部分を確定、後戻りしない。最後の1語は保留 = hold_last)
 2) 用語補正(asr/correct_terms.py)を確定語に適用。複数語の別名(clawed code 等)は前半の語を保留
 3) 節の閉じ判定: make_clause_chunks.py のルールを確定語の流れに逐次適用(CONJ はそのコードの値)
 4) 早期の最終訳: 区間が early_after 秒を超えたら、閉じた節までを先に送る
 3') 節の区切り方(10/29 sim/clause_rules.py の v4): look_conj(and/or)は次の語が主語らしい(SUBJ)ときだけ、その手前で閉じる。
    keep_conj(which/where)では閉じない。smart_max なら max_clause で切るとき、末尾の前置詞・冠詞など(DANGLING)の手前で切る
 5) 辞書にない語の確定待ち(hold_unknown 秒 > 0 のとき): 合意した先頭に辞書(asr/vocab.txt)にも用語集にもない語があれば、
    その語の手前で止める。同じ位置・同じ語を最初に見てから hold_unknown 秒たつか、最終結果が来たら確定する(10/29 sim/hold/hold_sim.py)
make_clause_chunks.py / local_agreement.py はそのまま残してある(こちらから import はしない)。"""
import json, re, os, sys, difflib
from dataclasses import dataclass

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(ROOT, "asr"))
import correct_terms

CONJ = {"and", "but", "because", "which", "where", "when", "if", "or", "while", "although"}
SUBJ = frozenset("i you we they he she it this that there the a an my our your their his her its so then now these those some many most all people everyone you're we're they're it's i'm there's that's".split())
DANGLING = frozenset("a an the to of for with from in on at by into about and or but which that who your their our my its his her is are was were be been can could will would should have has had do does not very more most so than as if when while".split())
W = lambda t: re.findall(r"[\w'’-]+[.,?!]?", t)
N = lambda w: re.sub(r"[^\w']", "", w.lower())


@dataclass
class Cfg:
    K: int = 2
    hold_last: int = 1
    min_clause: int = 4
    max_clause: int = 14
    early_after: float = 8.0
    correct: bool = True
    hold_unknown: float = 0.0   # 辞書にない語の確定を待つ最長秒数(0 = 待たない)
    look_conj: frozenset = frozenset()   # 次の語が主語らしいときだけ閉じる接続詞
    keep_conj: frozenset = frozenset()   # 閉じない接続詞
    smart_max: bool = False              # 上限で切るとき DANGLING の手前で切る
    look_subj: frozenset = SUBJ          # look_conj の後に来たら閉じる語(10/29 v6 は代名詞だけ)
    soft_max: int = 0                    # max_clause を超えても、この語数までは句読点を待つ(10/29 v6)


def load_cfg(path=None, **over):
    """jet.json から確定・節の設定を読む。over で上書き(None は無視)"""
    j = json.load(open(path or os.path.join(ROOT, "jet.json")))
    c = Cfg(K=j.get("K", 2), hold_last=j.get("hold_last", 0), min_clause=j.get("min_clause", 4), max_clause=j.get("max_clause", 14),
            early_after=j.get("early_after", 8.0), correct=j.get("correct", True), hold_unknown=j.get("hold_unknown_s", 0.0),
            look_conj=frozenset(j.get("look_conj", [])), keep_conj=frozenset(j.get("keep_conj", [])), smart_max=j.get("smart_max", False),
            look_subj=frozenset(j["look_subj"]) if "look_subj" in j else SUBJ, soft_max=j.get("soft_max", 0))
    for k, v in over.items():
        if v is not None: setattr(c, k, v)
    return c


def close_conj(cfg):
    return CONJ - cfg.look_conj - cfg.keep_conj


def load_terms():
    T, A = correct_terms.load()
    multi = [[N(t) for t in a.split()] for a, _ in A if len(a.split()) > 1]
    return T, A, multi


def load_segments(path):
    """[(volatileの塊のリスト, final)]。0.3秒以内の更新は最後の1つにまとめる(local_agreement.py と同じ)。"""
    segs, cur = [], []
    for l in open(path):
        if not l.strip():
            continue
        e = json.loads(l)
        k = e.get("kind")
        if k == "volatile":
            if cur and e["wall"] - cur[-1]["wall"] < 0.3:
                cur[-1] = e
            else:
                cur.append(e)
        elif k == "final":
            segs.append((cur, e))
            cur = []
    return segs


_VOCAB = None


def load_vocab(path=None):
    """辞書(1行1語、小文字)。Hunspell en_US を語形変化まで展開したもの(sim/hold/build_vocab.py)"""
    global _VOCAB
    if _VOCAB is None:
        _VOCAB = set(open(path or os.path.join(ROOT, "asr", "vocab.txt")).read().split())
    return _VOCAB


def known_words(T, A):
    """用語集の語と、別名表の直し先の語(待たない)"""
    return {N(x) for t in T for x in t.split()} | {N(x) for _, c in A for x in c.split()}


def suspicious(w, V, known):
    n = N(w)
    if not n or n.isdigit() or re.fullmatch(r"\d+(st|nd|rd|th|s)?", n):
        return False
    if n in V or n in known:
        return False
    if "'" in n and n.split("'")[0] in V:
        return False
    return True


def hold_cut(last, start, n, wall, since, max_hold, V, known):
    """last[start:n] の中で、待つべき語(辞書にない・まだ max_hold 秒たっていない)の位置を返す。なければ n"""
    for j in range(start, n):
        w = last[j]
        if suspicious(w, V, known):
            t0 = since.setdefault((j, N(w)), wall)
            if wall - t0 < max_hold:
                return j
    return n


def held_count(raw, multi):
    best = 0
    for toks in multi:
        for s in range(min(len(toks) - 1, len(raw)), 0, -1):
            if [N(w) for w in raw[-s:]] == toks[:s]:
                best = max(best, s)
                break
    return best


def process_segment(batches, fin, cfg, T, A, multi):
    corr = (lambda s: correct_terms.correct(s, T, A)) if cfg.correct else (lambda s: s)
    fin_raw = W(fin["text"])
    fw = W(corr(fin["text"]))
    nfw = max(len(fw), 1)
    a0 = fin["audio_start"]
    dur = fin["audio_end"] - a0
    spoken = lambda k: a0 + min(k + 1, nfw) / nfw * dur

    raw, emitted, etime = [], [], []
    clauses, units, events, unsent, cur = [], [], [], [], []
    st = {"unstable": 0}
    unit_start = batches[0]["wall"] if batches else fin["wall"]

    cc = close_conj(cfg)
    look = {"on": False}

    def close(t, upto=None):
        part = cur[:upto] if upto is not None else list(cur)
        ks = [k for _, k in part]
        c = dict(idx=len(clauses), text=" ".join(w for w, _ in part), n=len(part), k0=ks[0], k1=ks[-1],
                 t_close=t, spoken_end=spoken(ks[-1]), unit=None)
        clauses.append(c); unsent.append(c); del cur[:len(part)]
        events.append(dict(t=t, kind="clause", idx=c["idx"], text=c["text"], spoken_end=c["spoken_end"]))

    def feed(w, k, t):
        n = N(w)
        if look["on"]:
            look["on"] = False
            if n in cfg.look_subj and len(cur) - 1 >= cfg.min_clause:
                close(t, len(cur) - 1)
        if cur and n in cc and len(cur) >= cfg.min_clause:
            close(t)
        cur.append((w, k))
        ends = bool(re.search(r"[,;.?!]$", w))
        if ends and len(cur) >= cfg.min_clause:
            close(t); return
        if n in cfg.look_conj and not ends:
            look["on"] = True
        if len(cur) >= cfg.max_clause + cfg.soft_max:
            look["on"] = False
            if cfg.smart_max:
                i = len(cur)
                while i > cfg.min_clause and N(cur[i - 1][0]) in DANGLING:
                    i -= 1
                if N(cur[i - 1][0]) not in DANGLING:
                    close(t, i); return
            close(t)

    def commit(t, flush):
        held = 0 if (flush or not cfg.correct) else held_count(raw, multi)
        part = raw[:len(raw) - held]
        c = W(corr(" ".join(part))) if cfg.correct else list(part)
        if len(c) < len(emitted):
            st["unstable"] += 1
            return
        words = []
        for w in c[len(emitted):]:
            k = len(emitted)
            emitted.append(w); etime.append(t); words.append(w)
            feed(w, k, t)
        if words:
            events.append(dict(t=t, kind="commit", words=words, flush=flush))

    def send(t, early):
        nonlocal unit_start
        u = dict(t_trigger=t, early=early, clauses=[c["idx"] for c in unsent],
                 n_words=sum(c["n"] for c in unsent), spoken_end=unsent[-1]["spoken_end"])
        for c in unsent:
            c["unit"] = len(units)
        units.append(u); unsent.clear(); unit_start = t
        events.append(dict(t=t, kind="final_req", early=early, n_clauses=len(u["clauses"]), n_words=u["n_words"]))

    hist = []
    since = {}
    if cfg.hold_unknown > 0:
        V, known = load_vocab(), known_words(T, A)
    for b in batches:
        hist.append(W(b["text"]))
        if len(hist) >= cfg.K:
            ws = hist[-cfg.K:]
            n = 0
            while all(len(w) > n for w in ws) and len({N(w[n]) for w in ws}) == 1:
                n += 1
            if n == len(ws[-1]):
                n = max(n - cfg.hold_last, 0)
            if cfg.hold_unknown > 0:
                n = hold_cut(ws[-1], len(raw), n, b["wall"], since, cfg.hold_unknown, V, known)
            if n > len(raw):
                raw.extend(ws[-1][len(raw):n])
                commit(b["wall"], False)
        if unsent and b["wall"] - unit_start >= cfg.early_after:
            send(b["wall"], True)

    n_la = len(emitted)
    raw.extend(fin_raw[len(raw):])
    commit(fin["wall"], True)
    if cur:
        close(fin["wall"])
    if unsent:
        send(fin["wall"], False)

    a = [N(w) for w in emitted[:n_la]]
    b = [N(w) for w in fw[:n_la + 3]]
    ok = set()
    for blk in difflib.SequenceMatcher(None, a, b, autojunk=False).get_matching_blocks():
        ok.update(range(blk.a, blk.a + blk.size))
    bad = {k for k in range(len(a)) if k not in ok}
    for c in clauses:
        c["stale"] = any(k in bad for k in range(c["k0"], c["k1"] + 1))
    return dict(emitted=emitted, etime=etime, spoken=[spoken(k) for k in range(len(emitted))],
                n_la=n_la, bad=bad, fw=fw, clauses=clauses, units=units, events=events,
                unstable=st["unstable"], a0=a0, a1=fin["audio_end"])
