#!/usr/bin/env python3
"""下書きベンチのテストセットを作る: 実際の live のイベントの節(clause)の英語 + mic-chunks.tsv の塊。重複は除く。
出力 results/draft-set.jsonl  1行1件 {"id", "src", "en"}。本番で AFM に渡したのと同じ英語(用語補正の後)。
使い方(リポジトリのルートで): python3 sim/make_draft_set.py"""
import json, os
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
# (名前, ファイル, 説明)
SOURCES = [
    ("rec1", "results/flow-20261029-122826.jsonl", "公開動画 1人・技術"),
    ("rec2", "results/flow-20261029-121250.jsonl", "公開動画 1人"),
    ("rec3", "results/flow-20261029-120309.jsonl", "公開動画 2人の対談"),
    ("rec4", "logs/jet-20261029-112429.jsonl", "公開動画(試走)"),
]


def main():
    seen, out, counts = set(), [], {}
    for name, path, _ in SOURCES:
        n = 0
        for l in open(os.path.join(ROOT, path), encoding="utf-8"):
            if not l.strip():
                continue
            e = json.loads(l)
            if e.get("kind") != "clause":
                continue
            en = (e.get("text") or "").strip()
            if not en or en in seen:
                continue
            seen.add(en); n += 1
            out.append(dict(id="%s-%04d" % (name, n), src=name, en=en))
        counts[name] = n
    n = 0
    for l in open(os.path.join(ROOT, "mic-chunks.tsv"), encoding="utf-8"):
        p = l.rstrip("\n").split("\t")
        en = (p[1] if len(p) > 1 else p[0]).strip()
        if not en or en in seen:
            continue
        seen.add(en); n += 1
        out.append(dict(id="mic-%04d" % n, src="mic", en=en))
    counts["mic"] = n
    path = os.path.join(ROOT, "results", "draft-set.jsonl")
    with open(path, "w", encoding="utf-8") as f:
        for r in out:
            f.write(json.dumps(r, ensure_ascii=False) + "\n")
    print("テストセット: %d 件  %s" % (len(out), "  ".join("%s %d" % kv for kv in counts.items())))
    print("出力: results/draft-set.jsonl")


if __name__ == "__main__":
    main()
