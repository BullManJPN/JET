#!/usr/bin/env python3
"""認識ログの比較。使い方: python3 asr/compare_logs.py <基準ログ> <比べるログ>... 
基準ログの final 全文を正解とみなして、各ログの WER(基準との違い)、語数、用語ヒット数を出す"""
import json, re, sys
sys.path.insert(0, "asr")

def norm_words(t):
    return re.findall(r"[a-z0-9']+", t.lower().replace("-", " "))

def wer(ref, hyp):
    d = list(range(len(hyp) + 1))
    for i in range(1, len(ref) + 1):
        prev, d[0] = d[0], i
        for j in range(1, len(hyp) + 1):
            cur = min(d[j] + 1, d[j - 1] + 1, prev + (ref[i - 1] != hyp[j - 1]))
            prev, d[j] = d[j], cur
    return d[len(hyp)] / max(1, len(ref))

def load(p):
    ev = [json.loads(l) for l in open(p, encoding="utf-8")]
    return norm_words(" ".join(e["text"] for e in ev if e.get("kind") == "final"))

terms = [l.strip() for l in open("asr/terms.txt", encoding="utf-8") if l.strip()]
def count(words, term):
    t = norm_words(term); n = 0
    for i in range(len(words) - len(t) + 1):
        if words[i:i + len(t)] == t: n += 1
    return n
def term_hits(w): return sum(count(w, t) for t in terms)

ref = load(sys.argv[1])
print("基準: %s  %d語  用語ヒット %d" % (sys.argv[1], len(ref), term_hits(ref)))
for p in sys.argv[2:]:
    h = load(p)
    print("比較: %s  %d語  用語ヒット %d  基準とのWER %.1f%%" % (p, len(h), term_hits(h), 100 * wer(ref, h)))
