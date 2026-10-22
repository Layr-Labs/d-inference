"""Local-only configuration/source assembly from a passing diagnostic native build."""
from pathlib import Path
import base64
import copy
import difflib
import hashlib
import json
import uuid

BASE = Path(__file__).resolve().parent
ROOT = BASE.parent
OLD = ROOT / 'qwen27b-owner-diagnostic-drain-rerun-20260915'
BUILD = ROOT / 'qwen27b-resident-load-diagnostics-build-20260915'
REMOTE = '/Users/developer/DarkbloomDev/qwen27b-owner-load-operands-20260915'
OLD_REMOTE = '/Users/developer/DarkbloomDev/qwen27b-owner-validation-20260915'
UNCHANGED = ['parent_cleanup.py', 'parent_settings.py', 'probe_postflight.py', 'lease_source.py',
    'monitor.py', 'reference_resources.py', 'stage_checks/__init__.py', 'stage_checks/common.py',
    'test_parent_cleanup.py', 'inputs/prompt.ids.json', 'inputs/request.json', 'configuration/matrix.json']


def pin(path):
    raw = path.read_bytes()
    return dict(path=str(path), bytes=len(raw), sha256=hashlib.sha256(raw).hexdigest())


def write(name, value, compact=False):
    path = BASE / name
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open('x') as out:
        json.dump(value, out, sort_keys=True, **({'separators': (',', ':')} if compact else {'indent': 2}))
        out.write('\n')
    path.chmod(0o600)


def copied(name, target=None):
    path = BASE / (target or name)
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open('xb') as out:
        out.write((OLD / name).read_bytes())
    path.chmod(0o600)


def main():
    assert pin(OLD / 'manifest.json')['sha256'] == '5cd3b30c1b2c7f4d5672b9c68d2644578c36c661afc1d71b3d2072bde236c61a'
    build = json.loads((BUILD / 'native-1/receipt.json').read_bytes())
    assert build['passed'] and build['binarySHA256'] == '989f701ca6a8178ebc41b73e840a937c17aa9b0a3f8a53b9fee8432a4cd5ffdb'
    bundle = json.loads((BUILD / 'runtime-bundle-1/bundle.json').read_bytes())
    assert pin(BUILD / 'runtime-bundle-1/bundle.json')['sha256'] == '44ca36d0366501b78fe1e150bd9b5849988335cb0980bfc8cc9989d4b56b2536'
    for row in bundle['files']:
        observed = pin(BUILD / 'runtime-bundle-1' / row['path'])
        assert observed['bytes'] == row['bytes'] and observed['sha256'] == row['sha256']
    native = build['binarySHA256']
    epoch = str(uuid.uuid4())
    for name in UNCHANGED:
        copied(name)
    for name in ['run_physical.py', 'preflight.py', 'preparation/remote_preflight.py']:
        copied(name, 'originals/' + name)
        text = (OLD / name).read_text().replace(OLD_REMOTE, REMOTE)
        path = BASE / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
    patch = ''.join(''.join(difflib.unified_diff((OLD / name).read_text().splitlines(True),
        (BASE / name).read_text().splitlines(True), fromfile='a/' + name, tofile='b/' + name))
        for name in ['run_physical.py', 'preparation/remote_preflight.py'])
    (BASE / 'binding.patch').write_text(patch)
    def ready(encoded):
        raw = base64.b64decode(encoded, validate=True)
        assert raw.endswith(b'\n') and raw.count(b'\n') == 1
        value = json.loads(raw)
        for peer in value['ready']['identity']['peers']:
            assert peer['buildSHA256'] == 'a7c35b37c2ae2f80c320221ac9931bdd3f87d7e7cd67b2d5cfbc93a8eb043ad6'
            peer['buildSHA256'] = native
        return base64.b64encode((json.dumps(value, sort_keys=True, separators=(',', ':')) + '\n').encode()).decode()
    for name in ['configuration/controller.json', 'configuration/owner-rank0.json', 'configuration/owner-rank1.json']:
        copied(name, 'originals/' + name)
        value = json.loads((OLD / name).read_bytes())
        value['readyTemplateBase64'] = ready(value['readyTemplateBase64'])
        if name.endswith('controller.json'):
            value['membershipEpoch'] = epoch
            for peer in value['peers']:
                peer['installedOwner'] = peer['installedOwner'].replace(OLD_REMOTE, REMOTE)
        else:
            value['workerExecutable'] = value['workerExecutable'].replace(OLD_REMOTE, REMOTE)
            value['workerEnvironment'] = {k: v.replace(OLD_REMOTE, REMOTE) for k, v in value['workerEnvironment'].items()}
        write(name, value, compact=True)
    copied('provenance/recording-metadata.json', 'originals/recording-metadata.json')
    metadata = json.loads((OLD / 'provenance/recording-metadata.json').read_bytes())
    metadata['nativeBinarySHA256'] = native
    metadata['readyTemplatesBase64'] = [ready(x) for x in metadata['readyTemplatesBase64']]
    write('provenance/recording-metadata.json', metadata, compact=True)
    deployment = copy.deepcopy(json.loads((OLD / 'deployment.json').read_bytes()))
    for rank in deployment['ranks']:
        rank['remoteRoot'] = REMOTE
        for item in rank['directories']:
            item['mode'] = '0700'
        for item in rank['files']:
            name = item['path']
            if name in {x['path'] for x in bundle['files']}:
                source = BUILD / 'runtime-bundle-1' / name
            elif name == 'owner.json':
                source = BASE / ('configuration/owner-rank' + str(rank['rank']) + '.json')
            elif name == 'matrix.json':
                source = BASE / 'configuration/matrix.json'
            elif (BASE / name).is_file():
                source = BASE / name
            else:
                source = Path(item['source'])
            observed = pin(source)
            if name == 'darkbloom-cluster-worker':
                item['role'] = 'native_load_operand_diagnostics'
            item.update(source=str(source), bytes=observed['bytes'], sha256=observed['sha256'],
                        mode='0700' if name in ['darkbloom-cluster-worker', 'darkbloom-owner-qualification'] else '0600')
        files = {'owner/' + x['path']: dict(source=x['source'], bytes=x['bytes'], sha256=x['sha256'], mode=int(x['mode'], 8)) for x in rank['files']}
        write('deployment-rank' + str(rank['rank']) + '.json',
              dict(schema='qwen27b_load_operands_copy_only_tree_v1', files=files), compact=True)
    deployment.update(nativeBinaryChanged=True, remoteArtifactsChanged=True, remoteActionsExecuted=False)
    write('deployment.json', deployment)
    copied('expected-agreement.json', 'originals/expected-agreement.json')
    copied('comparison-gates.json', 'originals/comparison-gates.json')
    copied('provenance/expected-agreement-prepare-receipt.json', 'originals/expected-agreement-prepare-receipt.json')
    write('lineage.json', dict(oldParent=pin(OLD / 'manifest.json'), newEpoch=epoch,
        oldRemoteRoot=OLD_REMOTE, newRemoteRoot=REMOTE, unchangedInputs=UNCHANGED,
        nativeBuildReceipt=pin(BUILD / 'native-1/receipt.json'), nativeBundle=pin(BUILD / 'runtime-bundle-1/bundle.json'),
        sourceSnapshot=pin(BUILD / 'source-snapshot-1.json'), dependencySnapshot=pin(BUILD / 'dependency-snapshot-1.json'),
        diagnosticOverlay=pin(ROOT / 'qwen-resident-load-gate-diagnostics-draft-20260915/manifest.json'),
        nativeBinarySHA256=native, metadataChangeScope='only actual native build SHA and both ready peer build SHAs',
        requestBytesUnchanged=True, sourceStorageAndArithmeticDeclarationsUnchanged=True,
        actualReadinessObserved=False, candidateOutputsRead=False, remoteExecuted=False))
    print(json.dumps(dict(assembled=True, epoch=epoch, nativeSHA256=native, remoteRoot=REMOTE)))


if __name__ == '__main__':
    main()
