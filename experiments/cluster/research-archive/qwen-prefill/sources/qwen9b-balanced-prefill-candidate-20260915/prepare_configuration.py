"""Local-only case preparation from retained, pinned configuration and metadata."""
import base64
import copy
import hashlib
import json
from pathlib import Path
import uuid

BASE = Path(__file__).resolve().parent
RESEARCH = BASE.parent
REMOTE = '/Users/developer/DarkbloomDev/qwen9b-balanced-prefill-20260915'
KNOWN_HOSTS = RESEARCH / 'qwen-resident-mtp-registered-probe-qualification-20260915/configuration/known_hosts'
NATIVE_SHA = '009a671d4e355131b6f38166536d00eee0fb5798000407808d716bc3ea31a08b'
PROMPT_SHA = 'ee6caf0be6391e00ec41df930f0fd6351613969622cbb247b1b4bdaf69afe997'
CASES = {
    'cut4-correctness': (4, 'c44b1095-735d-47c0-8097-1ac52f182715'),
    'cut16-correctness': (16, 'c3c4d2d5-09cf-4ed5-bc84-93cf00d2ff38'),
    'cut4-timing': (4, '9403e063-8789-4867-9247-8446af5d150b'),
    'cut16-timing': (16, 'e7a7199c-5baf-439a-a459-e155a731d703'),
}

def record(value):
    return (json.dumps(value, sort_keys=True, separators=(',', ':'), allow_nan=False) + '\n').encode()

def load(path):
    return json.loads(path.read_bytes())

def ready_template(raw, plan, rank):
    value = json.loads(base64.b64decode(raw, validate=True))
    value['ready']['executionPlanSHA256'] = plan
    value['ready']['rank'] = rank
    # Identity/profile template only: real native readiness supplies capacity.
    value['ready']['requestCapacityBytes'] = 1
    return base64.b64encode(record(value)).decode()

def case_configuration(name):
    if name not in CASES:
        raise ValueError('Unknown closed candidate case')
    cut, epoch = CASES[name]
    assert str(uuid.UUID(epoch)) == epoch
    old = RESEARCH / 'owner-native-lookahead128-20260915/configuration'
    timing = name.endswith('-timing')
    controller = load(RESEARCH / 'owner-timing-lookahead-wakeup-20260915/configuration/controller.json' if timing else old / 'controller.json')
    source = load(BASE / f'metadata/cut{cut}.json')
    partition = load(BASE / 'partition-checks.json')['cuts'][str(cut)]
    prompt = (BASE / 'inputs/prompt.ids.json').read_bytes()
    if hashlib.sha256(prompt).hexdigest() != PROMPT_SHA or controller['promptTokenIDs'] != json.loads(prompt):
        raise ValueError('Matched prompt input changed')
    cluster = 'qwen9b-balanced-' + name
    remote = REMOTE + '/' + name
    controller.update(clusterID=cluster, membershipEpoch=epoch,
        readyTemplateBase64=ready_template(controller['readyTemplateBase64'], source['planFingerprint'], 0))
    if timing:
        controller['cohortLabel'] = name.replace('-', '_') + '_lookahead_warm1_measure3'
    for peer in controller['peers']:
        peer['installedOwner'] = remote + '/darkbloom-owner-qualification'
        peer['knownHostsFile'] = str(KNOWN_HOSTS)
    owners = []
    for rank in range(2):
        owner = load(old / f'owner-rank{rank}.json')
        owner.update(clusterID=cluster, stageCut=cut,
            leaseDirectory='/Users/developer/.darkbloom/cluster-device',
            workerExecutable=REMOTE + '/native/darkbloom-cluster-worker',
            readyTemplateBase64=ready_template(owner['readyTemplateBase64'], source['planFingerprint'], rank))
        owner['workerEnvironment']['DARKBLOOM_BENCHMARK_EVIDENCE_DIR'] = remote + '/evidence'
        owner['workerEnvironment']['JACCL_IBV_DEVICES'] = remote + '/matrix.json'
        owners.append(owner)
    agreement = load(old / 'expected-agreement.json')
    agreement.update(membershipEpoch=epoch, planFingerprint=source['planFingerprint'],
        stageFingerprints=[x['stagePlanSHA256'] for x in source['loads']],
        storageCommitmentSHA256=partition['storageCommitmentSHA256'])
    return controller, owners, load(old / 'matrix.json'), agreement

def prepare():
    output = BASE / 'cases'
    output.mkdir(exist_ok=False)
    for name in CASES:
        controller, owners, matrix, agreement = case_configuration(name)
        target = output / name / 'configuration'
        target.mkdir(parents=True)
        for filename, value in [('controller', controller), ('owner-rank0', owners[0]),
                ('owner-rank1', owners[1]), ('matrix', matrix)]:
            (target / (filename + '.json')).write_bytes(record(value))
        if name.endswith('-correctness'):
            (target / 'expected-agreement.json').write_bytes(record(agreement))
        (target.parent / 'case.json').write_bytes(record(dict(schema='qwen9b_balanced_prefill_case_v1',
            case=name, cut=CASES[name][0], membershipEpoch=CASES[name][1], remoteDirectory=REMOTE + '/' + name,
            promptRawSHA256=PROMPT_SHA, nativeSHA256=NATIVE_SHA,
            schedulingPolicy='oneChunkLookahead', mtpEnabled=False,
            correctnessRequiredBeforeTiming=True, actualExecutionPerformed=False)))

if __name__ == '__main__':
    prepare()
