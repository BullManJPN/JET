import re
aff=open('/usr/share/hunspell/en_US.aff',encoding='latin-1').read().splitlines()
rules={}  # flag -> (kind, cross, [(strip, add, cond)])
i=0
while i<len(aff):
    p=aff[i].split()
    if len(p)>=4 and p[0] in('SFX','PFX') and p[2] in('Y','N') and p[3].isdigit():
        kind,flag,n=p[0],p[1],int(p[3]); lst=[]
        for j in range(n):
            q=aff[i+1+j].split()
            strip='' if q[2]=='0' else q[2]; add=q[3].split('/')[0]; add='' if add=='0' else add
            cond=q[4] if len(q)>4 else '.'
            lst.append((strip,add,re.compile((cond+'$') if kind=='SFX' else ('^'+cond))))
        rules[flag]=(kind,lst); i+=n+1
    else: i+=1
V=set()
for l in open('/usr/share/hunspell/en_US.dic',encoding='latin-1').read().splitlines()[1:]:
    w,_,fl=l.partition('/')
    w=w.strip()
    if not w: continue
    V.add(w.lower())
    for f in fl:
        if f not in rules: continue
        kind,lst=rules[f]
        for strip,add,cond in lst:
            if kind=='SFX' and cond.search(w) and w.endswith(strip):
                V.add((w[:len(w)-len(strip)]+add).lower())
            if kind=='PFX' and cond.search(w) and w.startswith(strip):
                V.add((add+w[len(strip):]).lower())
open('vocab.txt','w').write('\n'.join(sorted(V)))
print(len(V),'語')
for t in ['neural','neurural','tasks','files','running','runningning','provider','provvider','machine','machineine','step','stepep','agent','aent','agentic','agetic','errors','erors','quantize','subagents','ollama','mlx','xcode','swiftui','api','gonna','okay','yeah']:
    print(t, t in V, end=' | ')
