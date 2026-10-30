#!/usr/bin/env python3
"""英文を節・句の塊に分け、翻訳用の一覧 results/chunks-input.json を作る。
使い方: python3 apple/make_chunks.py

粒度:
  clause : 句読点(, ; : . ? !)と接続詞/関係詞の直前で区切る
  w10    : clause の塊が10語を超えたら、中央付近の前置詞/to の直前で追加分割
  w7     : 同じく7語を超えたら追加分割
  full   : 区切りなし(文全体。比較の基準)
needed = その塊を「確定してよい」と言える時点で、聞こえている必要がある語数
         (句読点で終わる塊は最後の語まで。語の直前で切る塊は、次の1語を見るまで確定できない)
"""
import json, re, os

CONJ = {"and", "but", "so", "because", "which", "while", "when", "if", "although", "though",
        "since", "unless", "whereas", "or", "where", "whose"}
PREP = {"to", "of", "for", "in", "on", "with", "across", "between", "about", "at", "from", "by",
        "into", "before", "after", "than", "how", "what", "through", "over", "under"}
FILLER = {"um", "uh", "er", "hmm"}


def strip(w):
    return re.sub(r"[^\w']", "", w.lower())


def split_words(words, max_words):
    """words: [(index, token)] を塊に分ける。戻り値: [(chunk_tokens, last_index, cut_kind)]"""
    chunks, cur = [], []
    for pos, (i, w) in enumerate(words):
        sw = strip(w)
        # 接続詞の直前で区切る(手前に3語以上あるとき)
        if cur and sw in CONJ and len([t for _, t in cur if strip(t) not in FILLER]) >= 3:
            chunks.append((cur, cur[-1][0], "before"))
            cur = []
        cur.append((i, w))
        if re.search(r"[,;:.?!]$", w):
            chunks.append((cur, i, "punct"))
            cur = []
    if cur:
        chunks.append((cur, cur[-1][0], "end"))

    if not max_words:
        return chunks

    out = []
    for ch, last, kind in chunks:
        stack = [(ch, last, kind)]
        while stack:
            c, l, k = stack.pop(0)
            n = len(c)
            if n <= max_words:
                out.append((c, l, k))
                continue
            mid = n / 2
            cands = [p for p in range(3, n - 2) if strip(c[p][1]) in PREP]
            if not cands:
                out.append((c, l, k))
                continue
            p = min(cands, key=lambda q: abs(q - mid))
            left, right = c[:p], c[p:]
            stack = [(left, left[-1][0], "before"), (right, l, k)] + stack
    return out


def build(sentences):
    items = []
    for si, s in enumerate(sentences):
        tokens = list(enumerate(s.split()))
        n = len(tokens)
        items.append({"gran": "full", "si": si, "ci": 0, "text": s, "needed": n, "nwords": n, "last": n - 1})
        for gran, mw in (("clause", None), ("w10", 10), ("w7", 7)):
            for ci, (ch, last, kind) in enumerate(split_words(tokens, mw)):
                text = " ".join(t for _, t in ch)
                needed = last + 1 if kind in ("punct", "end") else last + 2
                items.append({"gran": gran, "si": si, "ci": ci, "text": text, "needed": min(needed, n),
                              "nwords": len(ch), "last": last, "cut": kind})
    return items


if __name__ == "__main__":
    here = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    sents = [l.strip() for l in open(os.path.join(here, "sentences.txt"), encoding="utf-8") if l.strip()]
    items = build(sents)
    out = os.path.join(here, "results", "chunks-input.json")
    json.dump(items, open(out, "w", encoding="utf-8"), ensure_ascii=False, indent=1)
    print("作成:", out, " 項目数:", len(items))
    for si in (4, 10):
        print("\n--- 文%d: %s" % (si, sents[si]))
        for g in ("clause", "w10", "w7"):
            print("  [%s] %s" % (g, " | ".join(i["text"] for i in items if i["gran"] == g and i["si"] == si)))
    for g in ("clause", "w10", "w7"):
        cs = [i for i in items if i["gran"] == g]
        print("%s: 塊 %d 個 / 平均 %.1f 語 / 最大 %d 語" % (g, len(cs), sum(c["nwords"] for c in cs) / len(cs), max(c["nwords"] for c in cs)))
