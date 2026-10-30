# PopModel.swift と同じ規則の Python 版(ポン差し替え型: 確定の欄 + 仮の1行)
import json, sys

class Cfg:
    min_s = 1.0; per_char_s = 0.0; max_chars = 66; coalesce = True

def strip_period(t):
    t = t.rstrip(' \n\t　')
    while t and t[-1] in '。．':
        t = t[:-1].rstrip(' \n\t　')
    return t

class Pop:
    def __init__(s, cfg=Cfg()):
        s.cfg = cfg; s.reset()
    def reset(s):
        s.clock = 0.0; s.queue = []; s.cur = None; s.prev = None; s.draft = None
        s.done = set(); s.stale = set(); s.units = {}; s.clause_en = {}; s.drafts = {}
        s.pop_id = 0; s.draft_id = 0; s.file = None; s.log = []
    def hold(s, n): return max(s.cfg.min_s, n * s.cfg.per_char_s)
    def deadline(s):
        if not s.queue or s.cur is None: return None
        return max(s.queue[0]['at'], s.cur['until'])
    def settle(s, now):
        while s.queue:
            f = s.queue[0]
            if s.cur is None:
                s.pop_id += 1
                s.cur = dict(id=s.pop_id, text=f['text'], failed=f['failed'], at=f['at'], until=f['at'] + s.hold(len(f['text'])))
                s.log.append(('pop', f['at'], f['at'], s.cur['text'])); s.queue.pop(0); continue
            c = s.cur
            if (s.cfg.coalesce and f['at'] < c['until'] and not f['failed'] and not c['failed']
                    and len(c['text']) + len(f['text']) <= s.cfg.max_chars):
                c['text'] += f['text']; c['until'] = max(c['until'], f['at'] + s.hold(len(f['text'])))
                s.log.append(('merge', f['at'], f['at'], f['text'])); s.queue.pop(0); continue
            t = max(f['at'], c['until'])
            if t > now: break
            s.prev = c['text']; s.pop_id += 1
            s.cur = dict(id=s.pop_id, text=f['text'], failed=f['failed'], at=t, until=t + s.hold(len(f['text'])))
            s.log.append(('pop', f['at'], t, f['text'])); s.queue.pop(0)
    def advance(s, now):
        s.clock = max(s.clock, now); s.settle(s.clock)
    def apply(s, e):
        k = e.get('kind')
        if k is None: return
        f = e.get('file')
        if isinstance(f, str):
            if s.file is not None and s.file != f: s.reset()
            s.file = f
        s.clock = max(s.clock, e.get('t', s.clock)); now = s.clock
        s.settle(now)
        seg = e.get('seg')
        if seg is None: return
        if k == 'clause':
            s.clause_en['%d#%d' % (seg, e['idx'])] = e.get('text', '')
        elif k == 'final_req':
            s.units['%d#%d' % (seg, e['unit'])] = list(e.get('clauses', []))
        elif k == 'clause_stale':
            key = '%d#%d' % (seg, e['idx'])
            if key in s.done: pass
            elif s.draft and s.draft['key'] == key: s.draft = None
            elif key not in s.drafts: s.stale.add(key)
        elif k == 'draft':
            if e.get('dropped') or e.get('late'): return
            key = '%d#%d' % (seg, e['idx'])
            if key in s.done or key in s.stale: return
            text = s.clause_en.get(key, '') if e.get('guard') else strip_period(e.get('ja', ''))
            if not text: return
            s.drafts[key] = text; s.draft_id += 1
            s.draft = dict(id=s.draft_id, key=key, seg=seg, text=text)
        elif k == 'final':
            ukey = '%d#%d' % (seg, e['unit'])
            cl = s.units.get(ukey)
            if cl is None:
                cl = sorted(int(x.split('#')[1]) for x in s.drafts if x.startswith('%d#' % seg) and x not in s.done)
            keys = ['%d#%d' % (seg, i) for i in cl]
            for x in keys: s.done.add(x)
            if s.draft and s.draft['key'] in keys: s.draft = None
            ja = e.get('ja', ''); err = e.get('error', '')
            failed = bool(err) or not ja
            text = ja if not failed else '、'.join(s.drafts[x] for x in keys if x in s.drafts)
            s.queue.append(dict(text=text, failed=failed, at=now))
        s.settle(now)

if __name__ == '__main__':
    p = Pop()
    for l in open(sys.argv[1]):
        if l.strip(): p.apply(json.loads(l))
    p.advance(1e9)
    for x in p.log: print('%-5s arrive %7.3f show %7.3f  %s' % x)
    print('pops', sum(1 for x in p.log if x[0]=='pop'), 'merges', sum(1 for x in p.log if x[0]=='merge'),
          'max extra %.3f' % max(x[2]-x[1] for x in p.log))
