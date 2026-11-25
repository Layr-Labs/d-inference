"""Source replay only; no compilation, materialization or native evaluation."""
import ast,hashlib,json
from pathlib import Path
ROOT=Path(__file__).resolve().parent

def pin(path):
 p=Path(path);assert p.is_file() and not p.is_symlink() and p.stat().st_size<=2*1024**2
 raw=p.read_bytes();return dict(path=str(p),bytes=len(raw),sha256=hashlib.sha256(raw).hexdigest())
def read(row,base=None):
 p=Path(row['path']);p=base/p if not p.is_absolute() else p
 assert pin(p)==dict(row,path=str(p)),str(p)
 return p.read_bytes()
def check():
 own=json.loads((ROOT/'source-inputs.json').read_bytes())
 for row in own['members']:read(row,ROOT)
 spec=json.loads((ROOT/'integration.json').read_bytes());base=json.loads(read(spec['baseSources']))
 for row in spec['contextPins']:read(row)
 expected={x['path']:x for x in base['files']};assert len(expected)==122
 transforms=json.loads((ROOT/'transforms.json').read_bytes())['files']
 for row in spec['files']:
  name=Path(row['target']).name;out=read(row['source'])
  assert expected.get(row['target'])==row['before']
  if row['before'] is not None:
   original=read(dict(row['before'],path=str(ROOT/'Original'/name))).decode();result=original
   for op in transforms[name]:
    assert result.count(op['before'])==1;result=result.replace(op['before'],op['after'])
   assert result.encode()==out
   for op in reversed(transforms[name]):
    assert result.count(op['after'])==1;result=result.replace(op['after'],op['before'])
   assert result==original
  expected[row['target']]=dict(path=row['target'],bytes=len(out),sha256=hashlib.sha256(out).hexdigest())
 assert [expected[x] for x in sorted(expected)]==json.loads((ROOT/'expected-sources.json').read_bytes())['files'] and len(expected)==123
 old=(ROOT/'Original/Gemma4MTPPullBatchOwner.swift').read_text();new=(ROOT/'Runtime/Gemma4MTPPullBatchOwner.swift').read_text()
 oldbody=old[old.index('        guard !failed, let pending, !submitted, !completed'):old.index('    func delivered()')]
 newbody=new[new.index('        guard !failed, let pending, !submitted, !completed'):new.index('    func delivered()')]
 assert oldbody==newbody,'Original single-batch execution/fences changed'
 split=new[new.index('    func execute('):new.index('    private func executeSingle(')]
 assert split.index('var tokens = try autoreleasepool') < split.index('pending = nil; submitted = false; completed = false; finalBatchCount = nil') < split.index('auxiliary.requireGrant(count:1,capture:capture)') < split.index('pending = try branch.build(grantedCount:1)')
 assert 'branch.build(grantedCount:3)' not in new and 'requireGrant(count:3' not in new
 oldtarget=(ROOT/'Original/Gemma4MTPPullTarget.swift').read_text();target=(ROOT/'Runtime/Gemma4MTPPullTarget.swift').read_text()
 assert oldtarget[oldtarget.index('    func fill('):oldtarget.index('    /// Submit lookahead')]==target[target.index('    func fill('):target.index('    /// Submit lookahead')]
 assert oldtarget[oldtarget.index('    func retireRejectedBranch('):]==target[target.index('    func retireRejectedBranch('):]
 for p in ROOT.rglob('*.py'):ast.parse(p.read_bytes(),str(p))
 assert len(spec['controlLabels'])==len(set(spec['controlLabels']))==16
 return spec
if __name__=='__main__':
 check();print(json.dumps(dict(status='source-checked',nativeSources=123,changedRuntimeFiles=9,controlsStaged=16,compilerExecuted=False,nativeExecuted=False)))
