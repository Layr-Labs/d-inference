"""Small source/retained-log checks only; never imports or runs the execution wrappers."""
import ast,difflib,hashlib,json,re
from pathlib import Path
BASE=Path(__file__).resolve().parent
def sha(p):return hashlib.sha256(Path(p).read_bytes()).hexdigest()
def require(v,message):
    if not v:raise ValueError(message)

def check():
    integration=json.loads((BASE/'integration.json').read_text());row,=integration['files']
    original=(BASE/'original'/row['path']).read_text();proposed=(BASE/'proposed'/row['path']).read_text()
    before='''                if case .ready(let ready) = frame.event {
                    try attachment?.requireCompleted()
                    if attachment?.profile.requiresNativeAuthorization == true {
                        guard let protectedReady else { throw OwnerWire.invalid("Native authorization/mesh alone cannot publish model readiness") }
                        try protectedReady.validate(ready)
                    }
                }
'''
    after=before.replace('                    try attachment?.requireCompleted()\n','').replace('                    }\n                }\n','                    }\n                    try attachment?.requireCompleted()\n                }\n')
    require(original.count(before)==1 and proposed==original.replace(before,after),'Only exact eligibility/wait reordering permitted')
    require(sha(BASE/'original'/row['path'])==row['beforeSHA256'] and sha(row['sourcePath'])==row['afterSHA256'],'Runtime pins differ')
    patch=''.join(difflib.unified_diff(original.splitlines(True),proposed.splitlines(True),fromfile='a/'+row['path'],tofile='b/'+row['path']))
    require((BASE/'runtime.patch').read_text()==patch,'Runtime inverse differs')
    prior=Path(integration['priorOutput']);snapshot=json.loads((prior/'candidate-before.json').read_text())
    require(len(snapshot)==13853 and snapshot[row['path']]=={'sha256':row['beforeSHA256']} and sha(prior/'candidate-before.json')==integration['actorCandidateSHA256'],'Actual candidate preimage differs')
    controls=json.loads((BASE/'source-check-inputs.json').read_text())
    for x in controls:
        require(sha(x['source'])==x['sha256'],'Source control changed')
        if 'local' in x:require(sha(BASE/x['local'])==x['sha256'],'Unchanged wrapper helper differs')
        if 'candidatePath' in x:require(snapshot[x['candidatePath']]=={'sha256':x['sha256']},'Fixture/control not from actual failed candidate')
    for x in json.loads((BASE/'evidence-pins.json').read_text()):
        p=Path(x['path']);require(p.stat().st_size==x['bytes'] and sha(p)==x['sha256'],'Retained failure evidence changed')
    discovery=json.loads((BASE/'discovered-coverage.json').read_text());text=Path(discovery['sourceStdout']).read_text()
    require(sha(discovery['sourceStdout'])==discovery['sourceSHA256'],'Discovery source changed')
    starts=[x for x in re.findall(r'^◇ Test (.+) started\.$',text,re.M) if x!='run' and not x.startswith('case ')]
    passed=[x for x in re.findall(r'^✔ Test (.+?) passed after [^\n]+$',text,re.M) if not x.startswith('run with ')]
    failed=[x for x in re.findall(r'^✘ Test (.+?) failed after [^\n]+$',text,re.M) if not x.startswith('run with ')]
    require(len(starts)==len(set(starts))==112 and sorted(starts)==discovery['startedLabels'],'Actual started membership differs')
    require(len(passed)==110 and failed==discovery['failedLabels'] and sorted(passed+failed)==discovery['completionLabels'],'Actual terminal membership differs')
    require(set(starts)=={re.sub(r' with \d+ test cases$','',x) for x in passed+failed},'Start/completion membership mismatch')
    prior_coverage=json.loads((BASE/'prior-coverage.json').read_text())
    old=set(prior_coverage['priorCompletionLabels'])|{n+'()' for names in prior_coverage['groups'].values() for n in names}
    require(sorted(set(passed+failed)-old)==discovery['additionalInheritedLabels'] and len(discovery['additionalInheritedLabels'])==5,'Five inherited configuration methods differ')
    require('✘ Test run with 112 tests in 18 suites failed after 10.073 seconds with 2 issues.' in text,'Actual failure summary differs')
    parsed=[]
    for p in sorted(BASE.glob('*.py')):ast.parse(p.read_text());parsed.append(p.name)
    checks=ast.parse((BASE/'test_coverage.py').read_text())
    require(sum(isinstance(x,ast.FunctionDef) and x.name.startswith('test_') for x in ast.walk(checks))==4,'Parser fixture method count differs')
    return dict(sourceOnly=True,runtimeFilesChanged=1,actualDiscoveredTests=112,actualDiscoveredSuites=18,
        actualPriorPassedMethods=110,actualPriorFailedMethods=2,unchangedSourceControls=len(controls),pythonASTFiles=len(parsed),
        originalSwiftFixturesUnchanged=True,fixtureOrCompilerOrModelOrRemoteExecuted=False)
if __name__=='__main__':print(json.dumps(check(),sort_keys=True))
