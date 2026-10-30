# s3 などのイベント(.jsonl)から commit のかたまりを抜き出す → gloss-chunks.txt(1行1かたまり)と gloss-chunks.json(seg・時刻・その文の最終訳)
# 使い方(リポジトリのルートで): python3 sim/make_gloss_chunks.py results/s3-20261028-154425.jsonl
import json, sys

src = sys.argv[1] if len(sys.argv) > 1 else 'results/s3-20261028-154425.jsonl'
ev = [json.loads(l) for l in open(src) if l.strip()]
finals = {}
for e in ev:
    if e['kind'] == 'final':
        finals[e['seg']] = finals.get(e['seg'], '') + e.get('ja', '')
segtext = {e['seg']: e['text'] for e in ev if e['kind'] == 'seg'}
rows = []
for e in ev:
    if e['kind'] != 'commit':
        continue
    en = ' '.join(e['words']).strip()
    if not en:
        continue
    rows.append({'seg': e['seg'], 't': e['t'], 'en': en, 'n_words': len(e['words']),
                 'seg_en': segtext.get(e['seg'], ''), 'final_ja': finals.get(e['seg'], '')})
open('gloss-chunks.txt', 'w').write('\n'.join(r['en'].replace('\t', ' ') for r in rows) + '\n')
json.dump({'source': src, 'chunks': rows}, open('gloss-chunks.json', 'w'), ensure_ascii=False, indent=1)
n = [r['n_words'] for r in rows]
print(f'{len(rows)} かたまり(1〜{max(n)}語、平均 {sum(n)/len(n):.1f}語)→ gloss-chunks.txt / gloss-chunks.json')
