"""Pin the fully composed inventory and exact inherited dependency files."""
from pathlib import Path
import hashlib,json
from build_inputs import BASE,WORKSPACE,SCRATCH,inputs,entries

def main():
    v,old,previous,overlay,exclude=inputs();removed={r['path'] for r in exclude}
    expected={r['path']:r for r in previous if r['path'] not in removed}
    for row in overlay:
        raw=Path(row['source']).read_bytes();expected[row['path']]=dict(path=row['path'],bytes=len(raw),sha256=hashlib.sha256(raw).hexdigest())
    source=entries(WORKSPACE);deps=entries(SCRATCH/'checkouts')
    if source!=sorted(expected.values(),key=lambda r:r['path']) or len(source)!=v['expectedSourceCount']:raise ValueError('Composed source inventory differs')
    if deps!=json.loads((old/'dependency-snapshot-1.json').read_bytes())['members']:raise ValueError('Inherited dependency inventory differs')
    for name,rows in [('source-snapshot-1.json',source),('dependency-snapshot-1.json',deps)]:
        with (BASE/name).open('x') as f:json.dump(dict(members=rows),f,indent=2);f.write('\n')
    print(json.dumps(dict(sources=len(source),dependencyFiles=len(deps),compilerExecuted=False)))
if __name__=='__main__':main()
