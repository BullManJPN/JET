#!/usr/bin/env python3
"""ASR後処理: 用語辞書による補正 (確定的な別名 + 保守的なあいまい一致)。
usage: python3 asr/correct_terms.py <log.jsonl> [terms.txt] [aliases.tsv]   差分を表示
       import して correct(text) も使える"""
import sys,re,json,difflib,os
H=os.path.dirname(os.path.abspath(__file__))
def load(terms=H+'/terms.txt',aliases=H+'/term_aliases.tsv'):
    T=[l.strip() for l in open(terms) if l.strip()]
    A=[]
    for l in open(aliases):
        if l.startswith('#') or not l.strip(): continue
        p=l.rstrip('\n').split('\t'); A.append((p[0],p[1]))
    return T,A
def correct(text,T,A,thr=0.84):
    out=text
    for a,c in A:
        out=re.sub(r'\b'+re.sub(r' ',r'[\\s-]+',re.escape(a).replace('\\ ',' '))+r'\b',c,out,flags=re.I)
    # 大文字小文字の正規化 (anthropic -> Anthropic など)
    for t in T:
        out=re.sub(r'\b'+re.escape(t)+r'\b',t,out,flags=re.I)
    # あいまい一致: 1語用語のみ、5文字以上、先頭文字一致、完全一致語は触らない
    single=[t for t in T if ' ' not in t and len(t)>=5]
    def fz(m):
        w=m.group(0)
        if w in T: return w
        for t in single:
            if w[0].lower()==t[0].lower() and abs(len(w)-len(t))<=2 \
               and difflib.SequenceMatcher(None,w.lower(),t.lower()).ratio()>=thr: return t
        return w
    return re.sub(r"[A-Za-z]{5,}",fz,out)
if __name__=='__main__':
    T,A=load(*sys.argv[2:4]) if len(sys.argv)>2 else load()
    n=0
    for l in open(sys.argv[1]):
        e=json.loads(l)
        if e.get('kind')!='final': continue
        c=correct(e['text'],T,A)
        if c!=e['text']:
            n+=1; print('- '+e['text'].strip()); print('+ '+c.strip()); print()
    print(n,'文を補正')
