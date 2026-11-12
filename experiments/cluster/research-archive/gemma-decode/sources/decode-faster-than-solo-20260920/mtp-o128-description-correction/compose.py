"""One-file guarded source composition. Only root invokes --apply."""
import argparse,hashlib,json
from pathlib import Path
ROOT=Path(__file__).resolve().parent
def sha(b):return hashlib.sha256(b).hexdigest()
def pin(path):
    b=path.read_bytes();return dict(path=str(path),bytes=len(b),sha256=sha(b))
def read(row,root=None):
    p=Path(row['path']);p=p if p.is_absolute() else root/p
    assert p.is_file() and not p.is_symlink() and p.stat().st_size<=2*1024**2
    b=p.read_bytes();assert (len(b),sha(b))==(row['bytes'],row['sha256']),str(p)
    return b
def check():
    for row in json.loads((ROOT/'source-inputs.json').read_bytes())['members']:read(row,ROOT)
    spec=json.loads((ROOT/'integration.json').read_bytes());base=json.loads(read(spec['baseSources']))
    read(spec['helper']);read(spec['failedMetadata'])
    expected=json.loads((ROOT/'expected-sources.json').read_bytes())['files']
    files={r['path']:r for r in base['files']};assert len(files)==len(base['files'])==122
    assert len(spec['files'])==1
    row=spec['files'][0];assert files[row['target']]==row['before']
    original=read(dict(row['before'],path=str(ROOT/'preimages/Gemma4BenchmarkInput.swift')))
    corrected=read(row['source'])
    text=corrected.decode();old=original.decode()
    assert text.count(spec['newLoop'])==1 and text.replace(spec['newLoop'],spec['oldLoop'])==old
    assert text.count('for target in describedTargets')==1
    assert 'Gemma4BenchmarkResourceBudget.derive(plan: plan, target: target,' in text
    assert 'request: requests[0], captureEvidence: job.captureEvidence,' in text
    assert 'observedResidualDType: job.dtype' in text
    forward=read(spec['requestSource']).decode()
    assert 'activationDType: String(describing: observedResidualDType)' in forward
    enum=read(spec['typeSource']).decode()
    enum=enum[enum.index('enum Gemma4ForwardTarget'):enum.index('\n\nstruct Gemma4SelectedTensor')]
    assert (ROOT/'Tests/Gemma4ForwardTarget.swift').read_text()==enum+'\n'
    selection=spec['newLoop'][spec['newLoop'].index('        let describedTargets:'):spec['newLoop'].index('\n        for target in describedTargets')]
    assert (ROOT/'Tests/selection.txt').read_text()==selection+'\n'
    assert selection in (ROOT/'Tests/SelectionChecks.swift').read_text()
    files[row['target']]=dict(path=row['target'],bytes=len(corrected),sha256=sha(corrected))
    assert [files[k] for k in sorted(files)]==expected
    return spec,base,expected
def main():
    p=argparse.ArgumentParser(allow_abbrev=False);p.add_argument('--apply',action='store_true');p.add_argument('--output',type=Path)
    a=p.parse_args();spec,base,expected=check()
    if not a.apply:
        assert a.output is None;print(json.dumps(dict(status='source-checked',changedFiles=1,nativeSources=122,testsExecuted=False)));return
    assert a.output and a.output.is_absolute() and a.output.parent.resolve()==a.output.parent and not a.output.exists()
    workspace=Path(spec['workspace']);assert workspace.resolve()==workspace and base['workspace']==str(workspace)
    for row in base['files']:read(row,workspace)
    a.output.mkdir(mode=0o700)
    for row in spec['files']:
        before=read(row['before'],workspace);after=read(row['source'])
        (a.output/'Gemma4BenchmarkInput.before.swift').write_bytes(before)
        (a.output/'Gemma4BenchmarkInput.after.swift').write_bytes(after)
        (workspace/row['target']).write_bytes(after)
    for row in expected:read(row,workspace)
    result=dict(base,files=expected,workspaceMutated=True,compilerExecuted=False,
        outputDescriptionPredecessor=spec['baseSources'],outputDescriptionCorrectionManifestSHA256=pin(ROOT/'source-inputs.json')['sha256'],
        outputDescriptionCorrectionIntegrationSHA256=pin(ROOT/'integration.json')['sha256'])
    out=a.output/'sources.json';out.write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(pin(out)))
if __name__=='__main__':main()
