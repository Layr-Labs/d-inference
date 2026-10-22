"""Root-only Foundation/CryptoKit controls; no MLX, GPU, lease or socket use."""
import argparse
import hashlib
import json
import time
from pathlib import Path
from owned_process import invoke_controller

ROOT=Path(__file__).resolve().parent

def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def read(row):
    p=Path(row['path']);b=p.read_bytes()
    assert p.is_file() and not p.is_symlink() and len(b)==row['bytes'] and hashlib.sha256(b).hexdigest()==row['sha256'],p
    return b

def verify():
    for row in json.loads((ROOT/'source-inputs.json').read_bytes())['members']:
        read(dict(row,path=str(ROOT/row['path'])))
    spec=json.loads((ROOT/'inputs.json').read_bytes())
    for row in spec['sources']:read(row)
    assert read(spec['ownedHelper'])==(ROOT/'owned_process.py').read_bytes()
    for name in ['coreManifest','cohortManifest','denseManifest']:read(spec[name])
    return spec

def main():
    p=argparse.ArgumentParser(allow_abbrev=False);p.add_argument('--output',required=True,type=Path);a=p.parse_args()
    spec=verify();out=a.output
    assert out.is_absolute() and out.parent.resolve()==out.parent
    out.mkdir(mode=0o700)
    sources={Path(r['path']).name:r for r in spec['sources']}
    assert len(sources)==len(spec['sources'])
    receipt=dict(schema='gemma4_remote_foundation_controls_v1',steps=[],status='started',
                 sourceManifestSHA256=sha(ROOT/'source-inputs.json'),expectedGroups=24,
                 modelExecuted=False,gpuExecuted=False,mlxLinked=False,remoteExecuted=False,
                 physicalRetirementEstablished=False)
    def save():
        (out/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n')
    def run(name,argv,limit):
        step=dict(name=name,argv=argv);receipt['steps'].append(step);started=time.monotonic()
        try:
            with (out/(name+'.stdout')).open('xb') as stdout,(out/(name+'.stderr')).open('xb') as stderr:
                invoke_controller(argv,stdout,stderr,step,timeout=limit)
        finally:
            step['elapsedSeconds']=time.monotonic()-started
            for suffix in ['stdout','stderr']:
                path=out/(name+'.'+suffix)
                if path.exists():step[suffix+'SHA256']=sha(path);step[suffix+'Bytes']=path.stat().st_size
            save()
        assert step.get('exitCode')==0 and step.get('reaped') is True and step.get('groupAbsent') is True
        assert not step.get('failure') and step['stdoutBytes']<=1024**2 and step['stderrBytes']<=4*1024**2
    def path(name):return sources[name]['path']
    compiler=['/usr/bin/xcrun','swiftc','-swift-version','6','-warnings-as-errors','-j','2']
    try:
        common=[path(n) for n in ['AsyncMTPProposalLedger.swift','Gemma4MTPPullRecord.swift','Gemma4MTPPullTransferPlan.swift']]
        run('core-compile',compiler+common+[path('Gemma4MTPPullMirror.swift'),path('PullProtocolCheck.swift'),'-o',str(out/'pull-controls')],120)
        run('core-check',[str(out/'pull-controls')],15)
        value=json.loads((out/'core-check.stdout').read_bytes())
        assert value==dict(schema='gemma4_mtp_remote_pull_cpu_v1',passed=True,groups=spec['expectedCoreGroups'],
                           groupCount=18,modelExecuted=False,nativeExecuted=False,physicalRetirementEstablished=False)
        raw=read(sources['QwenLongPrefillTensorBudget.swift'])
        marker=b'/// Dimension-only input, independent of CLI, model constructors or wire formats.'
        assert raw.count(marker)==1
        checked=raw.split(marker)[0]
        assert b'import MLX' not in checked
        with (out/'CheckedBytes.swift').open('xb') as f:f.write(checked)
        receipt['checkedBytesSHA256']=hashlib.sha256(checked).hexdigest()
        run('budget-compile',compiler+common+[path('ClusterRuntimeError.swift'),path('ClusterMetadataHashing.swift'),
            str(out/'CheckedBytes.swift'),path('Gemma4MTPRemoteTargetBudget.swift'),path('RemoteTargetBudgetCheck.swift'),
            '-o',str(out/'budget-controls')],120)
        run('budget-check',[str(out/'budget-controls')],15)
        assert (out/'budget-check.stdout').read_text()==spec['expectedBudgetStdout']
        assert (out/'core-check.stderr').stat().st_size==(out/'budget-check.stderr').stat().st_size==0
        assert verify()==spec
        receipt.update(status='passed',coreGroups=18,budgetGroups=6,sourceInputsUnchanged=True)
    except BaseException as error:
        receipt.update(status='failed',error=type(error).__name__+': '+str(error))
        try:receipt['sourceInputsUnchanged']=verify()==spec
        except BaseException as changed:receipt['sourceRecheckError']=str(changed)
        raise
    finally:
        save()
        print(json.dumps(receipt))

if __name__=='__main__':main()
