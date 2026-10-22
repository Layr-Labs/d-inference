"""Prospective audit of two physical cancellation cases; no execution authority."""
import argparse
import base64
import hashlib
import json
from pathlib import Path
import re
from audit_io import Inputs, parse
from audit_records import canonical_uuid, integer, observations, require, resources, token_hash

RESEARCH = Path('/Users/developer/DarkbloomDev/cluster-research')
CONTROLLER = RESEARCH / 'owner-cancellation-recovery-draft-20260915'
MANIFEST = '0ddcf8031038ea62e08c5b4ee27ffeef5631a7bc7b8fdc01d940a60c2629434d'
NATIVE = '009a671d4e355131b6f38166536d00eee0fb5798000407808d716bc3ea31a08b'
OWNER = '7d7867783036ab80392647041cbace33c29fdea9d09bb296348650a20180fa4c'
PROMPT = '2984d2234bd3f50a77ce7d63be1ec67119a4cc2f870cc8ba4afc96b7ba64b560'
SELECTED = '892e92cbcb8da5e696ceddb2d8e9bcf57b7c4f4f16cea15d215c4d28303c8456'
PLAN = '67bf0b1bf94f229682df58ae1ae10c758e2a386d66d3e1b68146f5c090f6309f'
MODEL_CONFIG = 'c8e767de4953e58352fbc1acbf6615329075ed02fe16a36b8065714d85ee4423'
ARTIFACT = '127de76b4ef82b7aaa0acaac0ee31c784cff066eda64291f521f051469b7c24b'
PROFILE = dict(id='registered_qwen35_9b_greedy_generation_v1', vocabularySize=248320,
    maximumPromptTokens=8192, maximumOutputTokens=128, maximumChunkTokens=512, maximumContextTokens=8320)


def frozen(inputs):
    manifest = inputs.obj(CONTROLLER / 'manifest.json')
    require(inputs.pins[str(CONTROLLER / 'manifest.json')] == MANIFEST, 'Controller manifest differs')
    require(len(manifest['members']) == 137, 'Controller member count differs')
    for name, row in manifest['members'].items():
        path = CONTROLLER / name
        require(not Path(name).is_absolute() and '..' not in Path(name).parts, 'Invalid manifest path')
        value = inputs.raw(path)
        require(len(value) == row['bytes'] and inputs.pins[str(path)] == row['sha256'], 'Frozen controller member differs')
    return inputs.obj(CONTROLLER / 'artifacts.json')['files']


def configuration(inputs, base, expected_case, artifacts):
    path = base / 'configuration/controller.json'; config = inputs.obj(path)
    require(config['schema'] == 'darkbloom_owner_cancellation_recovery_v1' and config['cancellationCase'] == expected_case, 'Configuration case differs')
    canonical_uuid(config['cancellationEpoch']); canonical_uuid(config['recoveryEpoch'])
    require(config['cancellationEpoch'] != config['recoveryEpoch'], 'Same membership epoch')
    require(len(config['promptTokenIDs']) == 8192 and token_hash(config['promptTokenIDs']) == PROMPT, 'Prompt differs')
    require(len(config['expectedTokenIDs']) == 128 and token_hash(config['expectedTokenIDs']) == SELECTED, 'Recovery reference sequence differs')
    integer(config['lifetimeSeconds'], 1, 300); integer(config['startupSeconds'], 1, min(90, config['lifetimeSeconds']))
    integer(config['requestSeconds'], 1, min(120, config['lifetimeSeconds']))
    integer(config['beforeFirstDelayMilliseconds'], 100, min(5000, config['requestSeconds'] * 1000 - 1))
    ready = parse(base64.b64decode(config['readyTemplateBase64'], validate=True))['ready']
    identity = ready['identity']
    require(identity['membershipEpoch'] == '00000000-0000-0000-0000-000000000000', 'Template must have zero placeholder epoch')
    require(identity['modelID'] == 'registered_qwen35_9b' and identity['artifactSHA256'] == ARTIFACT
        and identity['configurationSHA256'] == MODEL_CONFIG, 'Registered model identity differs')
    require(len(identity['peers']) == 2 and len({p['id'] for p in identity['peers']}) == 2
        and [p['buildSHA256'] for p in identity['peers']] == [NATIVE, NATIVE], 'Native membership differs')
    require(ready['profile'] == PROFILE and ready['executionPlanSHA256'] == PLAN and ready['rank'] == 0, 'Profile/Plan/template rank differs')
    require(len(config['peers']) == 2, 'Expected two owner endpoints')
    matrix = base / 'configuration/matrix.json'
    require(inputs.obj(matrix) == [[None, 'rdma_en1'], ['rdma_en1', None]], 'RDMA device matrix differs')
    for rank in (0, 1):
        owner_path = base / ('configuration/owner-rank%d.json' % rank); owner = inputs.obj(owner_path)
        owner_ready = parse(base64.b64decode(owner['readyTemplateBase64'], validate=True))['ready']
        require(owner_ready['identity'] == identity and owner_ready['profile'] == PROFILE
            and owner_ready['executionPlanSHA256'] == PLAN and owner_ready['rank'] == rank, 'Owner identity differs')
        require(owner['stageCut'] == 4 and owner['maximumLifetimeSeconds'] == 300 and owner['clusterID'] == config['clusterID'], 'Owner limits/cut differ')
        require(owner['workerEnvironment']['DARKBLOOM_BENCHMARK_PREFILL_POLICY'] == 'one_chunk_lookahead_v1'
            and owner['workerEnvironment']['JACCL_RANK'] == str(rank), 'Actual configured prefill policy/rank differs')
        deployment = inputs.obj(base / ('deployment-%d.json' % rank))
        require(deployment['exitCode'] == 0 and deployment['stderr'] == '', 'Owner deployment failed')
        verified = parse(deployment['stdout'])['verified']
        mapping = {v['path']: v['sha256'] for v in verified}
        require(len(mapping) == len(verified), 'Duplicate deployment path')
        owner_executable = Path(config['peers'][rank]['installedOwner'])
        wanted = {str(owner_executable): OWNER, str(owner_executable.parent / 'owner.json'): inputs.pins[str(owner_path)],
            str(owner_executable.parent / 'matrix.json'): inputs.pins[str(matrix)]}
        for name, item in artifacts.items():
            if name.startswith('lib'):
                wanted[str(owner_executable.parent / name)] = item['sha256']
        require(all(mapping.get(path) == digest for path, digest in wanted.items()), 'Deployed owner/config/module pin differs')
    return config


def execution(inputs, base, artifacts):
    out = base / 'physical-1'; value = inputs.obj(out / 'execution.json')
    require(value['controllerExitCode'] == value['leaseExitCode'] == 0 and value['pinsUnchanged'] is True
        and value['runCompletedAndAliasRestored'] is True, 'Physical execution or alias failed')
    require(all(v['exitCode'] == 0 and v['errors'] == [] for v in value['monitors']) and len(value['monitors']) == 2, 'Resource monitor failed')
    invocation = value['controllerInvocation']
    require(len(invocation) == 2 and invocation[1] == str(base / 'configuration/controller.json'), 'Controller invocation/config differs')
    binary = Path(invocation[0]); inputs.raw(binary)
    require(inputs.pins[str(binary)] == artifacts['owner-cancellation-controller']['sha256'], 'Wrong controller binary')
    pin_rows = inputs.obj(base / 'run-pins.json')['files']; pins = {v['path']: v['sha256'] for v in pin_rows}
    require(len(pins) == len(pin_rows) and pins.get(str(binary)) == inputs.pins[str(binary)], 'Runtime invocation is not pinned')
    for path, digest in pins.items():
        inputs.raw(Path(path)); require(inputs.pins[path] == digest, 'Run member differs from pin')
    for row in value['outputFiles']:
        require(Path(row['path']).name == row['path'], 'Unexpected output path')
        raw = inputs.raw(out / row['path'])
        require(len(raw) == row['bytes'] and hashlib.sha256(raw).hexdigest() == row['sha256'], 'Saved output differs')
    require(inputs.raw(out / 'controller.stderr') == b'', 'Controller stderr is nonempty')
    require(len(value['leaseFinal']) == 1 and value['aliasReady']['bridgeAndManagementStable'] is True, 'Alias lease history differs')
    lease = value['leaseFinal'][0]; require(lease['restored'] is True, 'Alias not restored')
    address = r'\binet\s+' + re.escape(lease['address']) + r'(?:\s|$)'
    before, after = lease['before'], lease['afterRemove']
    require(not re.search(address, before['en1']) and not re.search(address, after['en1']), 'Temporary alias remains')
    for interface in ['en1', 'bridge0']:
        require(re.search(r'flags=\d+<[^>]+>', before[interface])[0] == re.search(r'flags=\d+<[^>]+>', after[interface])[0], 'Interface flags changed')
    require(re.findall(r'member: (\S+)', before['bridge0']) == re.findall(r'member: (\S+)', after['bridge0']), 'Bridge members changed')
    require(re.search(r'interface:\s+(\S+)', before['managementRoute'])[1] == re.search(r'interface:\s+(\S+)', after['managementRoute'])[1], 'Management route changed')


def audit(base, expected_case):
    inputs = Inputs(); artifacts = frozen(inputs)
    config = configuration(inputs, base, expected_case, artifacts)
    execution(inputs, base, artifacts)
    result = observations(config, inputs.lines(base / 'physical-1/controller.stdout.jsonl'), inputs.pins[str(base / 'configuration/controller.json')])
    result['resources'] = []
    for rank in (0, 1):
        out = base / 'physical-1'
        result['resources'].append(dict(rank=rank, **resources(inputs.lines(out / ('resources-%d.jsonl' % rank)))))
        post = inputs.obj(out / ('postflight-%d.json' % rank))
        require(post['processes'] == [] and post['leaseFiles'] and all(integer(v['bytes']) == 0 for v in post['leaseFiles']), 'Postflight child/journal remains')
    result.update(schema='physical_owner_cancellation_audit_v1', passed=True, inputPins=inputs.pins,
        frozenControllerManifestSHA256=MANIFEST, nativeBinarySHA256=NATIVE,
        postflightJournalsZeroAndNoChildren=True, aliasRestored=True,
        independentRemoteCryptographicTranscriptReplay=False, nativeKernelPhaseObserved=False,
        freshRecoveryFullNumericalComparisonPerformed=False, externalTTFTMeasured=False,
        oldEpochReuseQualified=False, continuousResourceProof=False,
        scope='Retained record/pin audit. Pair creation ordering is source-enforced; request start is timestamped. Native build identity is declared/deployment-bound, not independently attested.')
    return result


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('cohort', type=Path)
    parser.add_argument('--case', required=True, choices=['startedBeforeFirstToken', 'afterFirstDecode'])
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    result = audit(args.cohort.resolve(), args.case)
    with args.output.open('x') as stream:
        json.dump(result, stream, sort_keys=True, indent=2); stream.write('\n')
    print(json.dumps({'passed': True, 'outputSHA256': hashlib.sha256(args.output.read_bytes()).hexdigest(),
        'case': args.case, 'resources': result['resources']}, sort_keys=True))
