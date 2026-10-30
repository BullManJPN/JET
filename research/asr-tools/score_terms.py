#!/usr/bin/env python3
"""認識ログと正解の文章を比べる。使い方: python3 asr/score_terms.py logs/asr-xxx.jsonl asr/term_scripts/term1.txt [asr/terms.txt]
出力: 単語誤り率(WER) と、用語ごとの正答率(正解に出てくる回数のうち、認識結果にも出た回数)"""
import json, re, sys

def norm_words(t):
    t = t.lower().replace("-", " ")
    return re.findall(r"[a-z0-9']+", t)

def wer(ref, hyp):
    d = list(range(len(hyp) + 1))
    for i in range(1, len(ref) + 1):
        prev, d[0] = d[0], i
        for j in range(1, len(hyp) + 1):
            cur = min(d[j] + 1, d[j - 1] + 1, prev + (ref[i - 1] != hyp[j - 1]))
            prev, d[j] = d[j], cur
    return d[len(hyp)] / max(1, len(ref))

def count(words, term):
    t = norm_words(term); n = 0
    for i in range(len(words) - len(t) + 1):
        if words[i:i + len(t)] == t: n += 1
    return n

log, refp = sys.argv[1], sys.argv[2]
terms = [l.strip() for l in open(sys.argv[3] if len(sys.argv) > 3 else "asr/terms.txt") if l.strip()]
ref = norm_words(open(refp, encoding="utf-8").read())
fin = [json.loads(l) for l in open(log, encoding="utf-8")]
hyp = norm_words(" ".join(e["text"] for e in fin if e.get("kind") == "final"))
meta = next((e for e in fin if e.get("kind") == "meta"), {})
print("ログ: %s  engine=%s terms=%s" % (log, meta.get("engine", "speech"), meta.get("terms_count", 0)))
print("WER: %.1f%%  (正解 %d 語 / 認識 %d 語)" % (100 * wer(ref, hyp), len(ref), len(hyp)))
tot = hit = 0
for t in terms:
    r = count(ref, t)
    if not r: continue
    h = min(r, count(hyp, t))
    tot += r; hit += h
    print("  %-22s %d/%d %s" % (t, h, r, "" if h == r else "  <-- 取りこぼし"))
print("用語の正答: %d/%d (%.0f%%)" % (hit, tot, 100 * hit / max(1, tot)))
