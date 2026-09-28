"""Local source/configuration inverses and exact deployment closure; never launches SSH."""
import ast
import base64
import copy
import json
from pathlib import Path
from assemble import BASE, ROOT, OLD, BUILD, REMOTE, OLD_REMOTE, UNCHANGED, pin


def load(path):
    return json.loads(path.read_bytes())


def ready(encoded):
    raw = base64.b64decode(encoded, validate=True)
    assert raw.endswith(b'\n') and raw.count(b'\n') == 1
    value = json.loads(raw)
    assert raw == (json.dumps(value, sort_keys=True, separators=(',', ':')) + '\n').encode()
    return value


def main():
    groups = []
    old_manifest = load(OLD / 'manifest.json')
    assert pin(OLD / 'manifest.json')['sha256'] == '5cd3b30c1b2c7f4d5672b9c68d2644578c36c661afc1d71b3d2072bde236c61a'
    for row in old_manifest['files']:
        value = pin(OLD / row['path'])
        assert (value['bytes'], value['sha256']) == (row['bytes'], row['sha256'])
    groups.append('all 65 frozen parent members unchanged')
    for name in UNCHANGED + ['preflight.py']:
        assert (BASE / name).read_bytes() == (OLD / name).read_bytes(), name
    for name in ['run_physical.py', 'preparation/remote_preflight.py']:
        assert (BASE / name).read_text().replace(REMOTE, OLD_REMOTE) == (OLD / name).read_text()
    groups.append('13 unchanged copies and two exact root-constant inverses')
    lineage = load(BASE / 'lineage.json')
    native = lineage['nativeBinarySHA256']
    previous_native = 'a7c35b37c2ae2f80c320221ac9931bdd3f87d7e7cd67b2d5cfbc93a8eb043ad6'
    def restore_ready(encoded):
        value = ready(encoded)
        assert value['membershipEpoch'] == '00000000-0000-0000-0000-000000000000'
        assert value['ready']['identity']['membershipEpoch'] == value['membershipEpoch']
        assert value['ready']['requestCapacityBytes'] == 1
        for peer in value['ready']['identity']['peers']:
            assert peer['buildSHA256'] == native
            peer['buildSHA256'] = previous_native
        return value
    for name in ['configuration/controller.json', 'configuration/owner-rank0.json', 'configuration/owner-rank1.json']:
        raw = (BASE / name).read_bytes()
        assert raw.endswith(b'\n') and raw.count(b'\n') == 1
        value, old = json.loads(raw), load(OLD / name)
        assert raw == (json.dumps(value, sort_keys=True, separators=(',', ':')) + '\n').encode()
        assert restore_ready(value['readyTemplateBase64']) == ready(old['readyTemplateBase64'])
        value['readyTemplateBase64'] = old['readyTemplateBase64']
        if name.endswith('controller.json'):
            assert value['membershipEpoch'] == lineage['newEpoch'] != old['membershipEpoch']
            value['membershipEpoch'] = old['membershipEpoch']
            for peer in value['peers']:
                peer['installedOwner'] = peer['installedOwner'].replace(REMOTE, OLD_REMOTE)
        else:
            assert value['stageCut'] == 32 and value['maximumLifetimeSeconds'] == 300
            value['workerExecutable'] = value['workerExecutable'].replace(REMOTE, OLD_REMOTE)
            value['workerEnvironment'] = {k: v.replace(REMOTE, OLD_REMOTE) for k, v in value['workerEnvironment'].items()}
        assert value == old, name
    groups.append('three compact JSONL configs: only epoch, root paths and both native Ready IDs change')
    metadata = load(BASE / 'provenance/recording-metadata.json')
    old_metadata = load(OLD / 'provenance/recording-metadata.json')
    restored = copy.deepcopy(metadata)
    assert restored['nativeBinarySHA256'] == native
    restored['nativeBinarySHA256'] = old_metadata['nativeBinarySHA256']
    assert [restore_ready(x) for x in restored['readyTemplatesBase64']] == [ready(x) for x in old_metadata['readyTemplatesBase64']]
    restored['readyTemplatesBase64'] = old_metadata['readyTemplatesBase64']
    assert restored == old_metadata
    agreement = load(BASE / 'expected-agreement.json')
    old_agreement = load(OLD / 'expected-agreement.json')
    assert agreement == dict(old_agreement, membershipEpoch=lineage['newEpoch'], rankBuildSHA256=[native, native])
    receipt = load(BASE / 'provenance/expected-agreement-prepare-receipt.json')
    assert receipt['exitCode'] == 0 and (BASE / 'provenance/agreement-preparer.stderr').read_bytes() == b''
    assert receipt['expectedAgreement'] == pin(BASE / 'expected-agreement.json')
    groups.append('actual corrected preparer receipt; metadata and agreement changes closed')
    old_sources = load(ROOT / 'qwen27b-owner-validation-build-20260915/source-snapshot.json')['members']
    new_sources = load(BUILD / 'source-snapshot-1.json')['members']
    a, b = ({x['path']: x for x in rows} for rows in [old_sources, new_sources])
    assert a.keys() == b.keys() and len(a) == 3040
    changed = [name for name in a if a[name] != b[name]]
    assert changed == ['libs/darkbloom-cluster/Sources/DarkbloomClusterRuntime/QwenResidentLoading.swift']
    assert b[changed[0]]['sha256'] == '80140c363e6a974293c2bd7203b5a1707473e66fd703e9be09e83ac3d3fa7361'
    assert load(BUILD / 'native-1/receipt.json')['passed'] is True
    groups.append('3040-source build differs only by reviewed operand observation file')
    deployment = load(BASE / 'deployment.json')
    old_deployment = load(OLD / 'deployment.json')
    assert deployment['localController'] == old_deployment['localController']
    assert deployment['localControlBundle'] == old_deployment['localControlBundle']
    for rank in [0, 1]:
        value = deployment['ranks'][rank]
        assert value['remoteRoot'] == REMOTE and len(value['files']) == 14
        plan = load(BASE / ('deployment-rank' + str(rank) + '.json'))
        assert plan['schema'] == 'qwen27b_load_operands_copy_only_tree_v1'
        assert plan['files'] == {'owner/' + x['path']: dict(source=x['source'], bytes=x['bytes'], sha256=x['sha256'], mode=int(x['mode'], 8)) for x in value['files']}
        old_files = {x['path']: x for x in old_deployment['ranks'][rank]['files']}
        for row in value['files']:
            actual = pin(Path(row['source']))
            assert (actual['bytes'], actual['sha256']) == (row['bytes'], row['sha256'])
            if row['path'] not in ['darkbloom-cluster-worker', 'owner.json']:
                assert row['sha256'] == old_files[row['path']]['sha256']
        assert {x['path'] for x in value['files']} == set(old_files)
    groups.append('both complete 14-file trees fully rehashed; only native and owner config bytes differ')
    source = (BASE / 'install_new_tree.py').read_text().replace(REMOTE, '/Users/developer/DarkbloomDev/qwen-resident-mtp-probe-clean-rerun-20260915')
    original = (BASE / 'originals/install_new_tree.py').read_text()
    # Compare the actual fixed root literal from the retained upstream source.
    original_root = next(line for line in original.splitlines() if line.startswith('ROOTS = '))
    source = '\n'.join(original_root if line.startswith('ROOTS = ') else line for line in source.splitlines()) + '\n'
    source = source.replace('qwen27b_load_operands_copy_only_tree_v1', 'mtp_probe_copy_only_tree_v1').replace('qwen27b_load_operands_copy_only_verification_v1', 'mtp_probe_copy_only_verification_v1')
    assert source == original
    tree = ast.parse((BASE / 'copy_owned.py').read_text())
    function = next(x for x in tree.body if isinstance(x, ast.FunctionDef))
    assert function.args.args[-1].arg == 'stdin'
    function.args.args.pop(); function.args.defaults.pop()
    popen = next(x for x in ast.walk(function) if isinstance(x, ast.Call) and isinstance(x.func, ast.Attribute) and x.func.attr == 'Popen')
    assert [x.arg for x in popen.keywords].count('stdin') == 1
    popen.keywords = [x for x in popen.keywords if x.arg != 'stdin']
    old_function = next(x for x in ast.parse((BASE / 'parent_cleanup.py').read_text()).body if isinstance(x, ast.FunctionDef) and x.name == 'invoke_controller')
    assert ast.dump(function) == ast.dump(old_function)
    groups.append('installer literal inverse and owned-child stdin-only AST inverse')
    for path in BASE.rglob('*.py'):
        ast.parse(path.read_text(), feature_version=(3, 9))
    assert not any((BASE / x).exists() for x in ['physical-1', 'copy-rank0-1', 'copy-rank1-1', 'preflight-1'])
    groups.append('all Python parses at 3.9 syntax; no remote or physical output directory')
    value = dict(passed=True, groups=groups, groupCount=len(groups), frozenParentMembersVerified=len(old_manifest['files']),
        nativeSHA256=native, expectedAgreement=pin(BASE / 'expected-agreement.json'),
        sourcePins=[pin(p) for p in sorted(BASE.rglob('*.py'))], compilerNativeModelOrRemoteExecuted=False)
    print(json.dumps(value, indent=2))


if __name__ == '__main__':
    main()
