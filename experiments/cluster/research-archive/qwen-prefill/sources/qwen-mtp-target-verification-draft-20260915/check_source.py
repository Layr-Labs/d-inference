from pathlib import Path
import hashlib,json,difflib,subprocess,tempfile
base=Path(__file__).resolve().parent
rel=Path('libs/darkbloom-cluster/Sources/DarkbloomClusterRuntime')
original=base/'originals'/rel;proposed=base/'proposed'/rel
def sha(p): return hashlib.sha256(p.read_bytes()).hexdigest()
checks=[]
def check(yes,name):
 if not yes: raise AssertionError(name)
 checks.append(name)
core=(proposed/'CBv2OwnedRequestState.swift').read_text()
core=core.replace('    private var verification: CBv2TargetVerification?\n','')
core=core.replace('evaluation == nil, verification == nil else','evaluation == nil else')
a=core.index('    func beginVerification('); b=core.index('    func validateState(',a);core=core[:a]+core[b:]
core=core.replace('        do { try verification?.discard() } catch { cleanupError = error }\n        verification = nil\n','')
core=core.replace('do { try evaluation.rollback() } catch { cleanupError = cleanupError ?? error }','do { try evaluation.rollback() } catch { cleanupError = error }')
check(core==(original/'CBv2OwnedRequestState.swift').read_text(),'ordinary Core exact inverse')
session=(proposed/'QwenLayerStageSession.swift').read_text()
session=session.replace('    private var verification: QwenTargetVerificationExecution?\n    private var usedVerificationRounds = Set<UUID>()\n','')
a=session.index('    /// Private opt-in seam;');b=session.index('    private func perform(',a);session=session[:a]+session[b:]
session=session.replace('        defer { verification?.discardOutputs(); verification = nil }\n','')
check(session==(original/'QwenLayerStageSession.swift').read_text(),'corrected MTP/ordinary Session exact inverse')
for item in json.loads((base/'base.json').read_text())['originals']:
 check(sha(base/'originals'/item['path'])==item['sha256'],'corrected proposal preimage '+Path(item['path']).name)
patch=''
for p in sorted(proposed.glob('*.swift')):
 old=original/p.name
 patch+=''.join(difflib.unified_diff(old.read_text().splitlines(True) if old.exists() else [],p.read_text().splitlines(True),fromfile='a/'+str(rel/p.name) if old.exists() else '/dev/null',tofile='b/'+str(rel/p.name)))
(base/'runtime.patch').write_text(patch)
with tempfile.TemporaryDirectory() as directory:
 d=Path(directory)
 for p in original.glob('*.swift'):
  out=d/rel/p.name;out.parent.mkdir(parents=True,exist_ok=True);out.write_bytes(p.read_bytes())
 subprocess.run(['git','apply','--check',str(base/'runtime.patch')],cwd=d,check=True,capture_output=True)
 subprocess.run(['git','apply',str(base/'runtime.patch')],cwd=d,check=True,capture_output=True)
 for p in proposed.glob('*.swift'):check(sha(p)==sha(d/rel/p.name),'patch exact '+p.name)
 subprocess.run(['git','apply','--reverse',str(base/'runtime.patch')],cwd=d,check=True,capture_output=True)
 for p in original.glob('*.swift'):check(sha(p)==sha(d/rel/p.name),'reverse exact '+p.name)
for item in json.loads((base/'foundation-inputs.json').read_text()):check(sha(base/item['retained'])==item['sha256'],'retained pure dependency '+Path(item['retained']).name)
result={'checks':checks,'count':len(checks),'passed':True,'swiftParsed':False,'swiftCompiled':False,'foundationFixtureExecuted':False,'nativeFixtureExecuted':False,'modelExecuted':False,'remoteOperations':False,'runtimeSources':[{'path':str(p.relative_to(base)),'sha256':sha(p)} for p in sorted(proposed.glob('*.swift'))],'runtimePatchSHA256':sha(base/'runtime.patch')}
(base/'source-checks.json').write_text(json.dumps(result,indent=2)+'\n')
print(json.dumps({'passed':True,'sourceChecks':len(checks),'nativeExecuted':False}))
