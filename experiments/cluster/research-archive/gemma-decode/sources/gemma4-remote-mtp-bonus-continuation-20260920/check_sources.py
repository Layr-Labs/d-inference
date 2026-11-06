"""Read only: verify saved source bytes and exact inverse; never apply or compile."""
import ast,hashlib,json
from pathlib import Path
ROOT=Path(__file__).resolve().parent

def sha(b):return hashlib.sha256(b).hexdigest()
def read(row,base=None):
    p=Path(row['path']);p=p if p.is_absolute() else base/p
    assert p.is_file() and not p.is_symlink() and p.stat().st_size<=2*1024**2
    b=p.read_bytes();assert (len(b),sha(b))==(row['bytes'],row['sha256']),str(p);return b

def check():
    for row in json.loads((ROOT/'source-inputs.json').read_bytes())['members']:read(row,ROOT)
    spec=json.loads((ROOT/'integration.json').read_bytes());base=json.loads(read(spec['baseSources']))
    expected=json.loads((ROOT/'expected-sources.json').read_bytes())['files']
    old={r['path']:r for r in base['files']};assert len(old)==len(base['files'])==122
    transforms={x['path']:x['changes'] for x in json.loads((ROOT/'transforms.json').read_bytes())['files']}
    for change in spec['files']:
        name=Path(change['target']).name;after=read(change['source']);before=change['before']
        if before is not None:
            assert old[change['target']]==before
            original=read(dict(before,path=str(ROOT/'preimages'/name))).decode();text=original
            for step in transforms[change['target']]:
                assert text.count(step['before'])==1;text=text.replace(step['before'],step['after'])
            assert text.encode()==after
            for step in reversed(transforms[change['target']]):
                assert text.count(step['after'])==1;text=text.replace(step['after'],step['before'])
            assert text==original
        else:assert change['target'] not in old
        old[change['target']]=dict(path=change['target'],bytes=len(after),sha256=sha(after))
    assert [old[k] for k in sorted(old)]==expected and len(expected)==123
    for pair in spec['foundationInputs']:
        copied=read(pair['copy']);assert len(copied)==pair['source']['bytes'] and sha(copied)==pair['source']['sha256']
    # Actual target arithmetic/verification call and all wire opcodes stay exact.
    target=(ROOT/'Runtime/Gemma4MTPPullTarget.swift').read_text()
    original=(ROOT/'preimages/Gemma4MTPPullTarget.swift').read_text()
    assert target[target.index('    func reseed('):]==original[original.index('    func reseed('):]
    for p in ROOT.rglob('*.py'):ast.parse(p.read_bytes(),str(p))
    return spec,expected

if __name__=='__main__':
    spec,expected=check();print(json.dumps(dict(status='source-checked',overlays=8,additions=1,nativeSources=len(expected),testsExecuted=False)))
