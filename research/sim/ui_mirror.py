import json, sys

class Cfg:
    min_focus_s = 1.0
    history_lines = 4

class Clause:
    def __init__(s, idx): s.idx = idx; s.en = ""; s.draft = None; s.guard = False; s.stale = False; s.final_unit = None
class Unit:
    def __init__(s, uid, clauses, en): s.uid = uid; s.clauses = list(clauses); s.en = en; s.ja = None; s.done = False; s.failed = False
class Sent:
    def __init__(s, seg): s.seg = seg; s.words = []; s.clauses = {}; s.units = {}; s.consumed = 0; s.eligible = False

def strip_period(t):
    t = t.rstrip()
    while t and t[-1] in "。．": t = t[:-1]
    return t

class VM:
    def __init__(s, cfg=Cfg()):
        s.cfg = cfg; s.sents = {}; s.focus = None; s.since = 0.0; s.queue = []; s.entry = {}; s.shown = set(); s.clock = 0.0; s.log = []
    def sent(s, seg):
        if seg not in s.sents: s.sents[seg] = Sent(seg)
        return s.sents[seg]
    def deadline(s):
        return max(s.since + s.cfg.min_focus_s, s.entry[s.queue[0]]) if (s.queue and s.focus is not None) else None
    def advance(s, now):
        while True:
            d = s.deadline()
            if d is None or d > now: break
            s.focus = s.queue.pop(0); s.since = d; s.log.append((d, 'focus', s.focus))
    def make_eligible(s, seg, now):
        if seg in s.shown: return
        s.shown.add(seg)
        if s.focus is None:
            s.focus = seg; s.since = now; s.log.append((now, 'focus', seg)); return
        if seg < s.focus: return  # straight to history
        s.queue.append(seg); s.queue.sort(); s.entry[seg] = now
    def apply(s, e, now=None):
        now = e.get('t', 0) if now is None else now
        s.clock = max(s.clock, now); now = s.clock
        s.advance(now)
        k = e['kind']; seg = e.get('seg')
        if seg is None: return
        S = s.sent(seg)
        if k == 'commit': S.words += e['words']
        elif k == 'clause':
            c = S.clauses.setdefault(e['idx'], Clause(e['idx'])); c.en = e['text']
        elif k == 'final_req':
            u = Unit(e['unit'], e['clauses'], e['en']); S.units[u.uid] = u; S.consumed += e['n_words']
            for i in u.clauses: S.clauses.setdefault(i, Clause(i)).final_unit = u.uid
        elif k == 'clause_stale':
            c = S.clauses.setdefault(e['idx'], Clause(e['idx']))
            if c.final_unit is not None and S.units[c.final_unit].done and not S.units[c.final_unit].failed: pass
            elif c.final_unit is not None and S.units[c.final_unit].done is False and False: pass
            else:
                c.stale = True
                if c.draft is None: s.make_eligible(seg, now)
        elif k == 'draft':
            if e.get('dropped') or e.get('late'): return
            c = S.clauses.setdefault(e['idx'], Clause(e['idx']))
            if c.final_unit is not None and S.units[c.final_unit].done and not S.units[c.final_unit].failed: return
            if c.stale and c.draft is None: return
            c.guard = bool(e.get('guard')); c.draft = (c.en if c.guard else strip_period(e.get('ja', '')))
            s.make_eligible(seg, now)
        elif k == 'final':
            u = S.units.get(e['unit'])
            if u is None:
                cov = {i for x in S.units.values() for i in x.clauses}
                u = Unit(e['unit'], [i for i in sorted(S.clauses) if i not in cov], ''); S.units[u.uid] = u
                for i in u.clauses: S.clauses[i].final_unit = u.uid
            u.done = True; u.ja = e.get('ja', '')
            if e.get('error') or not u.ja: u.failed = True
            if not u.failed or any(S.clauses[i].draft is not None or S.clauses[i].stale for i in u.clauses): pass
            s.make_eligible(seg, now)
        s.advance(now)
    def parts(s, seg):
        S = s.sents[seg]; out = []; seen = set()
        for i in sorted(S.clauses):
            c = S.clauses[i]; u = S.units.get(c.final_unit) if c.final_unit is not None else None
            if u is not None and u.done and not u.failed:
                if u.uid in seen: continue
                seen.add(u.uid); out.append(('final', u.ja))
            elif c.draft is not None: out.append(('stale' if c.stale else 'draft', c.draft))
            elif c.stale: out.append(('wait', '…'))
        return out

def run(path, show=True):
    vm = VM()
    for l in open(path):
        if not l.strip(): continue
        e = json.loads(l); vm.apply(e)
        if show and e['kind'] in ('draft','final','clause_stale'):
            print('%7.3f %-12s seg%d focus=%s queue=%s  seg parts=%s' % (e['t'], e['kind'], e['seg'], vm.focus, vm.queue, vm.parts(e['seg']) if e['seg'] in vm.sents else None))
    return vm
if __name__ == '__main__':
    vm = run(sys.argv[1])
    print([(round(t,3),k,v) for t,k,v in vm.log])
