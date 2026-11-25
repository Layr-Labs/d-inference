"""Small configuration/closure check; --artifacts is root's later full rehash gate."""
import argparse
import ast
import base64
import hashlib
import json
from pathlib import Path

BASE = Path(__file__).resolve().parent
ROOT = BASE.parent
OLD = ROOT/'qwen27b-owner-load-operands-rerun-20260915'
OLD_ROOT = '/Users/developer/DarkbloomDev/qwen27b-owner-load-operands-20260915'
REMOTE = '/Users/developer/DarkbloomDev/qwen27b-cut32-resource-pilot-20260916'
OLD_NATIVE = '989f701ca6a8178ebc41b73e840a937c17aa9b0a3f8a53b9fee8432a4cd5ffdb'
NATIVE = 'c35c585cfcd31e54e9635253e74a74fac35e704d83619b50aff007bac1f3f830'


def sha(path):
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for part in iter(lambda:stream.read(1024*1024),b''): digest.update(part)
    return digest.hexdigest()


def value(name): return json.loads((BASE/name).read_bytes())


def old_ready(encoded):
    raw=base64.b64decode(encoded,validate=True)
    assert raw.endswith(b'\n') and raw.count(b'\n')==1
    row=json.loads(raw)
    for peer in row['ready']['identity']['peers']:
        assert peer['buildSHA256']==NATIVE
        peer['buildSHA256']=OLD_NATIVE
    return row


def check(artifacts=False):
    lineage=value('lineage.json')
    assert sha(OLD/'manifest.json')==lineage['ancestorManifestSHA256']
    for name in lineage['unchangedHelpers']:
        assert (BASE/name).read_bytes()==(OLD/name).read_bytes(),name
    for name in lineage['pathOnlyHelpers']:
        assert (BASE/name).read_bytes().replace(REMOTE.encode(),OLD_ROOT.encode())==(OLD/name).read_bytes(),name
    # Exact pre-existing copy-helper function; no new transport or supervision.
    function=lambda p:next(x for x in ast.parse(p.read_text()).body if isinstance(x,ast.FunctionDef) and x.name=='pin')
    assert ast.dump(function(BASE/'assemble.py'))==ast.dump(function(OLD/'assemble.py'))
    scope=value('pilot-scope.json')
    shared_path=ROOT/'qwen27b-matched-timing-inputs-draft-20260915/bound-inputs-1/shared-inputs.json'
    assert sha(shared_path)==scope['sharedInputSHA256']
    shared=json.loads(shared_path.read_bytes())
    for name in ['configuration/controller.json','configuration/owner-rank0.json','configuration/owner-rank1.json']:
        raw=(BASE/name).read_bytes()
        assert raw.endswith(b'\n') and raw.count(b'\n')==1
        current=json.loads(raw);old=json.loads((OLD/name).read_bytes())
        assert old_ready(current.pop('readyTemplateBase64'))==json.loads(base64.b64decode(old.pop('readyTemplateBase64')))
        if name.endswith('controller.json'):
            assert current['membershipEpoch']==scope['membershipEpoch']!=old['membershipEpoch']
            assert current['requestID']==scope['requestID']!=old['requestID']
            assert current['promptTokenIDs']==shared['promptTokenIDs'] and len(current['promptTokenIDs'])==8192
            assert current['expectedTokenIDs']==shared['expectedTokenIDs'] and len(current['expectedTokenIDs'])==128
            assert current['chunkSize']==512 and current['outputCount']==128 and current['stopTokenIDs']==[]
            assert (current['lifetimeSeconds'],current['startupSeconds'],current['requestSeconds'])==(300,90,120)
            for key in ['membershipEpoch','requestID','promptTokenIDs','expectedTokenIDs','chunkSize']:
                current[key]=old[key]
            for peer in current['peers']:peer['installedOwner']=peer['installedOwner'].replace(REMOTE,OLD_ROOT)
        else:
            assert current['stageCut']==32 and current['maximumLifetimeSeconds']==300
            assert current['leaseDirectory']=='/Users/developer/.darkbloom/cluster-device'
            current['workerExecutable']=current['workerExecutable'].replace(REMOTE,OLD_ROOT)
            env=current['workerEnvironment'];assert env['DARKBLOOM_BENCHMARK_PREFILL_POLICY']=='one_chunk_lookahead_v1'
            env['DARKBLOOM_BENCHMARK_PREFILL_POLICY']='serial_v1'
            current['workerEnvironment']={k:v.replace(REMOTE,OLD_ROOT) for k,v in env.items()}
        assert current==old,name
    metadata=value('provenance/recording-metadata.json');old=json.loads((OLD/'provenance/recording-metadata.json').read_bytes())
    assert metadata['stageCut']==32 and metadata['planSHA256']==scope['planSHA256']
    assert scope['planSHA256']=='980b0f6ece0a078c284143d8af05c1532c2fdd7f0a6b1a06682b7bcc94b377d3'
    assert metadata['nativeBinarySHA256']==NATIVE
    metadata['nativeBinarySHA256']=old['nativeBinarySHA256']
    assert [old_ready(x) for x in metadata.pop('readyTemplatesBase64')]==[json.loads(base64.b64decode(x)) for x in old.pop('readyTemplatesBase64')]
    assert metadata==old
    deployment=value('deployment.json')
    assert deployment['localController']['sha256']=='862f7a391afd8f490233db793034c1ec8648c52fd908ba39abbefbf46e899d78'
    for rank in deployment['ranks']:
        assert rank['remoteRoot']==REMOTE and len(rank['files'])==14
        lookup={x['path']:x for x in rank['files']}
        assert lookup['darkbloom-cluster-worker']['sha256']==NATIVE
        assert lookup['darkbloom-owner-qualification']['sha256']=='da5542b115279db5f3f6e0794d96cdaa54cff1d193bee8c9d4bb24edc870c8a8'
        copy_plan=value('deployment-rank'+str(rank['rank'])+'.json')
        assert copy_plan['schema']=='qwen27b_load_operands_copy_only_tree_v1'
        copy=copy_plan['files']
        assert copy=={'owner/'+x['path']:dict(source=x['source'],bytes=x['bytes'],sha256=x['sha256'],mode=int(x['mode'],8)) for x in rank['files']}
    for p in BASE.rglob('*.py'):
        if '__pycache__' not in p.parts:ast.parse(p.read_text(),filename=str(p))
    pins=value('run-pins.json')['files']
    for row in pins:
        path=Path(row['path'])
        if artifacts or str(path).startswith(str(BASE)+'/'):
            assert not path.is_symlink() and path.stat().st_size==row['bytes'] and sha(path)==row['sha256'],str(path)
    return dict(sourcePassed=True,unchangedHelpers=len(lineage['unchangedHelpers']),pathOnlyHelpers=3,
        outerAndReadyJSONLChecked=True,exactCut32PlanPreserved=True,filesPerRank=14,
        externalArtifactsRehashed=artifacts,modelOrRemoteExecuted=False,fullStateComparisonPerformed=False)


if __name__=='__main__':
    parser=argparse.ArgumentParser(allow_abbrev=False);parser.add_argument('--artifacts',action='store_true')
    print(json.dumps(check(parser.parse_args().artifacts),sort_keys=True))
