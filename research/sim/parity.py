#!/usr/bin/env python3
"""Swift版(jetcli --replay)の出力と、sim/dump_events.py の正解イベントを比べる。
比べるもの: 区間ごと(file, seg)の commit / clause / final_req / clause_stale の並びと本文。時刻(t)や訳(ja)などの余分な項目は無視。
使い方(リポジトリのルートで): python3 sim/parity.py <jetcliの出力.jsonl> [results/golden-events.jsonl]
終了コード 0 = 完全一致 / 1 = 食い違いあり"""
import json, sys, collections
KEYS = {"seg": ["text"], "commit": ["words", "flush"], "clause": ["idx", "text"],
        "final_req": ["unit", "early", "n_clauses", "n_words", "en"], "clause_stale": ["idx"]}


def load(path):
    g = collections.OrderedDict()
    for l in open(path):
        if not l.strip():
            continue
        e = json.loads(l)
        k = e.get("kind")
        if k not in KEYS:
            continue
        g.setdefault((e["file"], e["seg"]), []).append((k, tuple(json.dumps(e.get(x), ensure_ascii=False) for x in KEYS[k])))
    return g


def main():
    act = load(sys.argv[1])
    gold = load(sys.argv[2] if len(sys.argv) > 2 else "results/golden-events.jsonl")
    bad = 0
    for key in sorted(set(gold) | set(act)):
        g, a = gold.get(key), act.get(key)
        # seg の見出しは位置を問わない。残りの並びを比べる
        gs = [x for x in (g or []) if x[0] != "seg"]
        as_ = [x for x in (a or []) if x[0] != "seg"]
        gh = [x for x in (g or []) if x[0] == "seg"]
        ah = [x for x in (a or []) if x[0] == "seg"]
        if g is None or a is None or gs != as_ or gh != ah:
            bad += 1
            if bad <= 8:
                print("食い違い:", key, "(正解なし)" if g is None else "(出力なし)" if a is None else "")
                if g is not None and a is not None:
                    for i in range(max(len(gs), len(as_))):
                        x = gs[i] if i < len(gs) else None
                        y = as_[i] if i < len(as_) else None
                        if x != y:
                            print("  #%d 正解: %s\n      出力: %s" % (i, x, y)); break
    n = len(gold)
    print("区間 %d 中 %d 件が食い違い" % (n, bad) if bad else "完全一致: %d 区間" % n)
    sys.exit(1 if bad else 0)


main()
