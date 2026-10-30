#!/usr/bin/env python3
"""マイクログ(logs/asr-*-mic.jsonl)の確定テキストを1行1文で書き出す。使い方: python3 asr/extract_sentences.py
出力: mic-sentences.txt  (認識ミスもそのまま含める。3語未満は除外、重複は除外)"""
import json, glob, re, os
os.chdir(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
seen, out = set(), []
for f in sorted(glob.glob("logs/asr-*-mic.jsonl")):
    for l in open(f, encoding="utf-8"):
        e = json.loads(l)
        if e.get("kind") != "final":
            continue
        t = " ".join(e["text"].split())
        if len(re.findall(r"[\w'’-]+", t)) < 3 or t in seen:
            continue
        seen.add(t); out.append(t)
open("mic-sentences.txt", "w", encoding="utf-8").write("\n".join(out) + "\n")
print("mic-sentences.txt: %d 文" % len(out))
