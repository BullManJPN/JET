# かたまり訳の比較表を作る(最新の results/gloss-*-apple.json と results/bench-*-thinkoff-afm-gloss.json を使う)
# 使い方(リポジトリのルートで): python3 sim/gloss_report.py  → results/gloss-report-<日時>.html
import json, glob, html, statistics as st, datetime, re

meta = json.load(open('gloss-chunks.json'))
rows = meta['chunks']
def latest(pat):
    fs = sorted(glob.glob(pat))
    return fs[-1] if fs else None

engines = {}  # 名前 → {en: (ja, ms, err)}
fa = latest('results/gloss-*-apple.json')
if fa:
    for r in json.load(open(fa)):
        engines.setdefault('Apple ' + r['strategy'], {})[r['en']] = (r['ja'], r['ms'], r['ja'].startswith('ERROR'))
fm = latest('results/bench-*-thinkoff-afm-gloss.json')
if fm:
    for r in json.load(open(fm)):
        engines.setdefault('AFM', {})[r['en']] = (r['text'], r['total_ms'], bool(r.get('error')))
names = list(engines)

def has_ja(s):
    return bool(re.search(r'[぀-ヿ一-鿿]', s))

summary = []
for n in names:
    ms = [v[1] for v in engines[n].values() if not v[2]]
    err = sum(1 for v in engines[n].values() if v[2])
    nj = sum(1 for v in engines[n].values() if not v[2] and not has_ja(v[0]))
    summary.append((n, st.median(ms) if ms else 0, max(ms) if ms else 0, err, nj, len(engines[n])))

out = ['<!doctype html><meta charset="utf-8"><title>かたまり訳の比較</title>',
       '<style>body{font:14px -apple-system,sans-serif;margin:24px;color:#222;background:#fff}'
       'table{border-collapse:collapse;width:100%}td,th{border-bottom:1px solid #ddd;padding:6px 8px;vertical-align:top;text-align:left}'
       'th{background:#f4f4f4;position:sticky;top:0}.seg td{background:#f7f9ff;color:#555;font-size:12px}'
       '.en{font-family:ui-monospace,monospace;color:#333}.ms{color:#999;font-size:11px}.bad{color:#c33}'
       '@media(prefers-color-scheme:dark){body{background:#1d1d1f;color:#eee}th{background:#2a2a2c}.seg td{background:#23263a;color:#aaa}td,th{border-color:#333}.en{color:#ddd}}</style>',
       f'<h1>かたまり訳の比較</h1><p>元: {html.escape(meta["source"])} の commit {len(rows)} かたまり。英語のかたまりを文脈なしで訳したもの(仮の欄に出す想定)。青い行はその文の最終訳(Haiku)。</p>',
       '<table><tr><th>エンジン</th><th>中央値</th><th>最大</th><th>エラー</th><th>日本語なし</th></tr>']
for n, med, mx, err, nj, cnt in summary:
    out.append(f'<tr><td>{n}</td><td>{med:.0f} ms</td><td>{mx:.0f} ms</td><td>{err}/{cnt}</td><td>{nj}/{cnt}</td></tr>')
out.append('</table><br><table><tr><th>時刻</th><th>英語のかたまり</th>' + ''.join(f'<th>{n}</th>' for n in names) + '</tr>')
prev_seg = None
for r in rows:
    if r['seg'] != prev_seg:
        prev_seg = r['seg']
        out.append(f'<tr class="seg"><td>seg {r["seg"]}</td><td colspan="{1+len(names)}">{html.escape(r["seg_en"])}<br>最終訳: {html.escape(r["final_ja"])}</td></tr>')
    cells = []
    for n in names:
        ja, ms, err = engines[n].get(r['en'], ('', 0, False))
        cls = ' class="bad"' if err or not has_ja(ja) else ''
        cells.append(f'<td{cls}>{html.escape(ja)} <span class="ms">{ms}ms</span></td>')
    out.append(f'<tr><td class="ms">{r["t"]:.1f}s</td><td class="en">{html.escape(r["en"])}</td>' + ''.join(cells) + '</tr>')
out.append('</table>')
path = 'results/gloss-report-' + datetime.datetime.now().strftime('%Y%m%d-%H%M%S') + '.html'
open(path, 'w').write('\n'.join(out))
for n, med, mx, err, nj, cnt in summary:
    print(f'{n:20s} 中央値 {med:4.0f} ms / 最大 {mx:4.0f} ms / エラー {err} / 日本語なし {nj} / {cnt}件')
print('表:', path, '  (open で開けます)')
