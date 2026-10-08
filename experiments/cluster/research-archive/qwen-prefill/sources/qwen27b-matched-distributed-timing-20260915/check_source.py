"""Validate matched timing bindings and exact parent inverses; artifacts opt-in."""
from pathlib import Path
import argparse
import ast
import base64
import copy
import hashlib
import json

BASE = Path(__file__).resolve().parent
OLD = BASE.parent / 'qwen27b-8k-lookahead-owner-qualification-20260915'
OLD_REMOTE = '/Users/developer/DarkbloomDev/qwen27b-8k-lookahead-owner-validation-20260915'


def load(path): return json.loads(path.read_bytes())
def digest(path): return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser=argparse.ArgumentParser(allow_abbrev=False)
    parser.add_argument('--artifacts', action='store_true')
    args=parser.parse_args()
    prepared=load(BASE/'prepared.json')
    assert digest(Path(prepared['sourceParent']['path']))==prepared['sourceParent']['sha256']
    policies=set(); epochs=set()
    for name, spec in prepared['cases'].items():
        case=BASE/name; remote=spec['remoteRoot']
        assert digest(case/'manifest.json')==spec['manifest']['sha256']
        for path,row in load(case/'manifest.json')['files'].items():
            p=case/path; assert p.stat().st_size==row['bytes'] and digest(p)==row['sha256'],str(p)
        for path in prepared['unchangedRuntimeFiles']:
            assert (case/path).read_bytes()==(OLD/path).read_bytes(),path
        for path in ('run_physical.py','install_new_tree.py','preparation/remote_preflight.py'):
            restored=(case/path).read_text().replace(remote,OLD_REMOTE)
            if path=='run_physical.py':
                restored=restored.replace('ROOT = BASE.parent.parent\n','ROOT = BASE.parent\n')
                restored=restored.replace("qwen9b-balanced-prefill-candidate-20260915/timing/runtime/owner-timing-controller",
                                          'cluster-owner-diagnostic-drain-draft-20260915/local-bundle/owner-controller')
            assert restored==(OLD/path).read_text(),path
        raw=(case/'configuration/controller.json').read_bytes()
        assert raw.endswith(b'\n') and raw.count(b'\n')==1
        config=json.loads(raw); previous=load(OLD/'configuration/controller.json')
        shared=load(Path(spec['sharedInputs']['path']))
        assert digest(Path(spec['sharedInputs']['path']))==spec['sharedInputs']['sha256']
        assert config['promptTokenIDs']==shared['promptTokenIDs'] and config['expectedTokenIDs']==shared['expectedTokenIDs']
        assert config['warmupCount']==1 and config['measuredCount']==3
        assert (config['lifetimeSeconds'],config['startupSeconds'],config['requestSeconds'])==(300,90,120)
        assert (len(config['promptTokenIDs']),config['chunkSize'],config['outputCount'],config['stopTokenIDs'])==(8192,512,128,[])
        assert config['membershipEpoch']==spec['membershipEpoch'] and config['membershipEpoch']!=previous['membershipEpoch']
        assert config['schema']=='darkbloom_owner_timing_cohort_v1'
        assert config['policyLabel']==spec['policyLabel'] and config['cohortLabel']=='qwen27b_cut16_'+name
        epochs.add(config['membershipEpoch']);policies.add(config['policyLabel'])
        restored=copy.deepcopy(config)
        for key in ('cohortLabel','policyLabel','warmupCount','measuredCount'):del restored[key]
        restored.update(schema=previous['schema'],requestID=previous['requestID'],membershipEpoch=previous['membershipEpoch'])
        for peer in restored['peers']:peer['installedOwner']=peer['installedOwner'].replace(remote,OLD_REMOTE)
        assert restored==previous
        for rank in (0,1):
            path='configuration/owner-rank'+str(rank)+'.json'; raw=(case/path).read_bytes()
            assert raw.endswith(b'\n') and raw.count(b'\n')==1
            owner=json.loads(raw); restored=copy.deepcopy(owner)
            assert owner['workerEnvironment']['DARKBLOOM_BENCHMARK_PREFILL_POLICY']==spec['policyLabel']
            restored['workerEnvironment']={k:v.replace(remote,OLD_REMOTE) for k,v in restored['workerEnvironment'].items()}
            restored['workerEnvironment']['DARKBLOOM_BENCHMARK_PREFILL_POLICY']='one_chunk_lookahead_v1'
            restored['workerExecutable']=restored['workerExecutable'].replace(remote,OLD_REMOTE)
            assert restored==load(OLD/path)
        for encoded in [config['readyTemplateBase64']]+[load(case/('configuration/owner-rank'+str(r)+'.json'))['readyTemplateBase64'] for r in (0,1)]:
            raw=base64.b64decode(encoded,validate=True); assert raw.count(b'\n')==1 and raw.endswith(b'\n')
            ready=json.loads(raw)['ready'];assert ready['requestCapacityBytes']==1
            assert [p['buildSHA256'] for p in ready['identity']['peers']]==[spec['nativeSHA256']]*2
        deployment=load(case/'deployment.json');old=load(OLD/'deployment.json')
        for rank,entry in enumerate(deployment['ranks']):
            assert len(entry['files'])==14 and entry['remoteRoot']==remote
            for actual,prior in zip(entry['files'],old['ranks'][rank]['files']):
                assert actual['path']==prior['path'] and actual['mode']==prior['mode']
                if actual['path']!='owner.json':assert (actual['bytes'],actual['sha256'])==(prior['bytes'],prior['sha256'])
            plan=load(case/('deployment-rank'+str(rank)+'.json'))
            assert len(plan['files'])==14
            assert plan['files']=={'owner/'+r['path']:dict(source=r['source'],bytes=r['bytes'],sha256=r['sha256'],mode=int(r['mode'],8)) for r in entry['files']}
        for row in load(case/'run-pins.json')['files']:
            path=Path(row['path'])
            # All local scripts/configs are checked; large external binaries
            # and matched resources remain declared until root's artifact pass.
            if args.artifacts or path.is_relative_to(BASE):
                assert path.stat().st_size==row['bytes'] and digest(path)==row['sha256'],str(path)
    assert len(epochs)==2 and policies=={'serial_v1','one_chunk_lookahead_v1'}
    for path in BASE.rglob('*.py'):ast.parse(path.read_text(),feature_version=(3,9))
    print(json.dumps(dict(passed=True,caseCount=2,rankFiles=14,unchangedParentFiles=12,
        rootAndControllerOnlyInverses=3,sharedPromptAnd128IDs=True,artifactsRehashed=args.artifacts,
        compilerNativeModelOrRemoteExecuted=False)))


if __name__=='__main__':main()
