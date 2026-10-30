#!/usr/bin/env python3
"""3ブロック表示(押し出し / 今読む / 待ち)で、確定文が実際の音声からどれだけ遅れて出るかを測る。
音声の時刻は認識ログ(logs/asr-*.jsonl)から取る:
  区間の最後の単位 → その区間の final 結果の audio_end(話し終わりの上限)
  先出しの単位     → その区間で語数が単位の終わりに達した最初の volatile の audio_end(約1秒刻みなので、最大約1秒遅めの上限)
表示の規則は Lyrics.swift / PopModel.swift と同じ(sim/pop_mirror.py を拡張):
  中央の文は 読む時間 = 字数 × per_char(min〜max 秒)は残す。その間に来た確定は「待ち」に出す。待ちが max_wait を超えたら中央をすぐ送る
使い方(リポジトリのルートで): python3 sim/lag_report.py [--per-char 0.1 --min 1.5 --max 5 --max-wait 1] [イベント.jsonl 認識ログ.jsonl ...]
引数なしなら s3 ×2本・s4b を使う"""
import json, sys, statistics as st, argparse

PAIRS = [('results/s3-20261028-154425.jsonl', 'logs/asr-20261028-154426-live.jsonl'),
         ('results/s3-20261028-153808.jsonl', 'logs/asr-20261028-153810-live.jsonl'),
         ('results/s4b-20261028-164448.jsonl', 'logs/asr-20261028-164450-live.jsonl')]


def q(xs, p):
    s = sorted(xs); return s[min(len(s) - 1, int(len(s) * p))]


def stat(xs):
    return 'n=0' if not xs else '中央値 %.2f / p90 %.2f / 最大 %.2f 秒 (n=%d)' % (st.median(xs), q(xs, .9), max(xs), len(xs))


def speech_ends(asr_path):
    """区間ごとに (final の audio_end, [語数 k に達した最初の volatile の audio_end]) を返す"""
    L = [json.loads(l) for l in open(asr_path) if l.strip()]
    segs, vol = [], []
    for x in L:
        if x.get('kind') == 'volatile':
            vol.append(x)
        elif x.get('kind') == 'final':
            first = {}
            for v in vol:
                n = len(v['text'].split())
                for k in range(1, n + 1):
                    first.setdefault(k, v['audio_end'])
            segs.append((x['audio_end'], first))
            vol = []
    return segs


def simulate(finals, per_char, mn, mx, max_wait):
    """finals: [(arrive, text)] 到着順。戻り値: 各確定の中央に上がった時刻・中央にいた時間"""
    hold = lambda s: min(mx, max(mn, len(s) * per_char))
    queue, cur, out = [], None, {}
    def settle(now):
        nonlocal cur
        while queue:
            i, at, text = queue[0]
            if cur is None:
                cur = [i, at, at + hold(text)]; out[i] = [at, None]; queue.pop(0); continue
            forced = max_wait > 0 and len(queue) > max_wait
            t = now if forced else max(at, cur[2])
            if t > now:
                break
            out[cur[0]][1] = t                 # 中央から押し出された時刻
            cur = [i, t, t + hold(text)]; out[i] = [t, None]; queue.pop(0)
    for i, (at, text) in enumerate(finals):
        settle(at)
        queue.append((i, at, text))
        settle(at)
    settle(1e9)
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--per-char', type=float, default=0.1)
    ap.add_argument('--min', type=float, default=1.5)
    ap.add_argument('--max', type=float, default=5.0)
    ap.add_argument('--max-wait', type=int, default=1)
    ap.add_argument('-v', action='store_true', help='確定ごとの表を出す')
    ap.add_argument('files', nargs='*')
    a = ap.parse_args()
    pairs = list(zip(a.files[::2], a.files[1::2])) if a.files else PAIRS
    tot = {'visible': [], 'center': [], 'dur': [], 'asr': [], 'wait': []}
    for ev_path, asr_path in pairs:
        E = [json.loads(l) for l in open(ev_path) if l.strip()]
        ends = speech_ends(asr_path)
        reqs = {(e['seg'], e['unit']): e for e in E if e['kind'] == 'final_req'}
        nwords = {}
        finals = []
        for e in E:
            if e['kind'] == 'final_req':
                nwords[e['seg']] = nwords.get(e['seg'], 0) + e['n_words']
                e['_k'] = nwords[e['seg']]
        for e in E:
            if e['kind'] != 'final':
                continue
            r = reqs.get((e['seg'], e['unit']))
            if e['seg'] >= len(ends) or r is None:
                continue
            fin_end, first = ends[e['seg']]
            sp = first.get(r['_k'], fin_end) if r['early'] else fin_end
            finals.append({'seg': e['seg'], 'unit': e['unit'], 'early': r['early'], 'speech_end': sp,
                           'req': r['t'], 'arrive': e['t'], 'ja': e['ja'], 'en': r['en']})
        finals.sort(key=lambda x: x['arrive'])
        out = simulate([(f['arrive'], f['ja']) for f in finals], a.per_char, a.min, a.max, a.max_wait)
        vis, cen, dur, asr, wt = [], [], [], [], []
        if a.v:
            print('\n' + ev_path)
            print('  区間  話し終わり  画面に出る(遅れ)  中央へ(遅れ)  中央にいた  文')
        for i, f in enumerate(finals):
            c0, c1 = out[i]
            vis.append(f['arrive'] - f['speech_end'])
            cen.append(c0 - f['speech_end'])
            wt.append(c0 - f['arrive'])
            asr.append(f['req'] - f['speech_end'])
            if c1 is not None:
                dur.append(c1 - c0)
            if a.v:
                print('  %3d%s  %7.2f   %6.2f (%+.2f)   %6.2f (%+.2f)   %s   %s' % (
                    f['seg'], '*' if f['early'] else ' ', f['speech_end'], f['arrive'], vis[-1], c0, cen[-1],
                    '  --  ' if c1 is None else '%5.2f秒' % (c1 - c0), f['ja'][:28]))
        for k, v in zip(['visible', 'center', 'dur', 'asr', 'wait'], [vis, cen, dur, asr, wt]):
            tot[k] += v
    print('設定: 読む時間 1字 %.2f 秒(%.1f〜%.1f 秒)、待ちは %d つまで。録音 %d 本、確定 %d 件' % (
        a.per_char, a.min, a.max, a.max_wait, len(pairs), len(tot['visible'])))
    print('  話し終えて → 最終訳を送るまで(認識の確定待ち): ', stat(tot['asr']))
    print('  話し終えて → 画面に出る(待ち or 中央)       : ', stat(tot['visible']))
    print('  話し終えて → 中央に上がる                   : ', stat(tot['center']))
    print('  画面に出て → 中央に上がるまでの待ち          : ', stat(tot['wait']))
    print('  中央にいた時間                              : ', stat(tot['dur']))


main()
