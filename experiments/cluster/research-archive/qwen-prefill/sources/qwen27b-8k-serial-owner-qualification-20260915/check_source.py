"""Verify source/input closure; optional actual artifact rehash is separate."""
import argparse
import ast
import base64
import json
from pathlib import Path
import sys
from assemble import BASE, pin


def load(path):return json.loads(path.read_bytes())

def verify_manifest(row):
    path=Path(row['path']);assert pin(path)==row
    value=load(path)['files']
    members=[dict(path=name,**item) for name,item in value.items()] if type(value) is dict else value
    for member in members:
        observed=pin(path.parent/member['path'])
        assert (observed['bytes'],observed['sha256'])==(member['bytes'],member['sha256'])


def main():
    parser=argparse.ArgumentParser(allow_abbrev=False);parser.add_argument('--artifacts',action='store_true');args=parser.parse_args()
    lineage=load(BASE/'lineage.json');old=Path(lineage['previousParent']['path']).parent
    inputs=Path(lineage['preparedInputs']['path']).parent;prior=lineage['oldRemoteRoot'];remote=lineage['newRemoteRoot']
    for key in ('previousParent','preparedInputs','comparator'):verify_manifest(lineage[key])
    for name in lineage['unchangedFiles']:assert (BASE/name).read_bytes()==(old/name).read_bytes(),name
    for name in ('run_physical.py','preparation/remote_preflight.py','install_new_tree.py'):
        assert (BASE/name).read_text().replace(remote,prior)==(old/name).read_text(),name
    for name in ('inputs/request.json','inputs/prompt.ids.json','provenance/recording-metadata.json','provenance/expected-identity.json','expected-agreement.json'):
        assert (BASE/name).read_bytes()==(inputs/name).read_bytes(),name
    for name in ('controller.json','owner-rank0.json','owner-rank1.json'):
        raw=(BASE/'configuration'/name).read_bytes();assert raw.endswith(b'\n') and raw.count(b'\n')==1
        current=json.loads(raw);source_name='serial-correctness-controller.json' if name=='controller.json' else name
        source=load(inputs/'configuration'/source_name)
        template=base64.b64decode(current['readyTemplateBase64'],validate=True)
        assert template.endswith(b'\n') and template.count(b'\n')==1
        event=json.loads(template);rank=0 if name=='controller.json' else int(name[-6])
        assert event['ready']['rank']==rank and event['ready']['requestCapacityBytes']==1
        assert all(p['buildSHA256']==lineage['nativeBinarySHA256'] for p in event['ready']['identity']['peers'])
        if name=='controller.json':
            assert current['membershipEpoch']==lineage['newEpoch'] and current['requestID']==lineage['requestID']
            assert len(current['promptTokenIDs'])==8192 and current['chunkSize']==512 and current['outputCount']==128
            assert current['expectedTokenIDs'] is None
            for peer in current['peers']:peer['installedOwner']=peer['installedOwner'].replace(remote,prior)
        else:
            assert current['stageCut']==16 and current['maximumLifetimeSeconds']==300
            assert current['workerEnvironment']['DARKBLOOM_BENCHMARK_PREFILL_POLICY']=='serial_v1'
            current['workerExecutable']=current['workerExecutable'].replace(remote,prior)
            current['workerEnvironment']={k:v.replace(remote,prior) for k,v in current['workerEnvironment'].items()}
        assert current==source,name
    assert (BASE/'configuration/matrix.json').read_bytes()==(old/'configuration/matrix.json').read_bytes()
    audit=Path(lineage['comparator']['path']).parent;sys.path.insert(0,str(audit))
    from audit_scope import pinned_scope
    from audit_common import request_context,agreement
    request=load(BASE/'inputs/request.json');scope=pinned_scope(request,load(BASE/'provenance/recording-metadata.json'))
    assert (scope.frames,scope.frontier)==(143,8319)
    context=request_context((BASE/'inputs/prompt.ids.json').read_bytes(),request['requestID'],scope)
    assert context['prompt_sha']==request['promptFileSHA256'] and context['prompt_tokens_sha']==request['promptTokenIDsSHA256']
    agreement(load(BASE/'expected-agreement.json'),context)
    deployment=load(BASE/'deployment.json');old_deployment=load(old/'deployment.json')
    for name in ('localController','localControlBundle','diagnosticOwnerBundle'):assert deployment[name]==old_deployment[name]
    unique={}
    for rank in (0,1):
        entry=deployment['ranks'][rank];assert entry['remoteRoot']==remote and len(entry['files'])==14
        raw=(BASE/('deployment-rank'+str(rank)+'.json')).read_bytes();assert raw.endswith(b'\n') and raw.count(b'\n')==1
        plan=json.loads(raw);assert plan['schema']=='qwen27b_load_operands_copy_only_tree_v1'
        assert plan['files']=={'owner/'+x['path']:dict(source=x['source'],bytes=x['bytes'],sha256=x['sha256'],mode=int(x['mode'],8)) for x in entry['files']}
        previous={x['path']:x for x in old_deployment['ranks'][rank]['files']}
        for row in entry['files']:
            if row['path']=='owner.json':
                actual=pin(BASE/('configuration/owner-rank'+str(rank)+'.json'))
                assert (row['bytes'],row['sha256'])==(actual['bytes'],actual['sha256'])
            else:assert (row['bytes'],row['sha256'])==(previous[row['path']]['bytes'],previous[row['path']]['sha256'])
            unique[row['source']]=row
    if args.artifacts:
        for filename,row in unique.items():
            actual=pin(Path(filename));assert (actual['bytes'],actual['sha256'])==(row['bytes'],row['sha256'])
    for path in BASE.rglob('*.py'):ast.parse(path.read_text(),feature_version=(3,9))
    assert not any((BASE/name).exists() for name in ('copy-rank0-1','copy-rank1-1','preflight-1','physical-1'))
    print(json.dumps(dict(passed=True,unchangedFiles=len(lineage['unchangedFiles']),rootOnlyInverses=3,
        compactConfigs=3,prospective8kScopeAndAgreement=True,rankDeploymentFiles=[14,14],
        externalArtifactSourcesVerified=len(unique) if args.artifacts else 0,compilerNativeModelOrRemoteExecuted=False),indent=2))


if __name__=='__main__':main()
