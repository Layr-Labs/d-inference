"""Offline C256 evidence replay. Never launches children or grants root approval."""
import argparse
import ast
import base64
from collections import Counter
from datetime import datetime
from decimal import Decimal
import hashlib
import importlib
import json
import math
import os
from pathlib import Path
import re
import stat
import sys

sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
EXPERIMENT = ROOT / 'resident-generation-phase-memory-draft-20260917/Experiment'
REFERENCE = EXPERIMENT / 'reference'
INPUTS = EXPERIMENT / 'inputs-1'
PARSERS = ROOT / 'qwen27b-8k-full-reference-20260915/package'
REQUEST = '72a2b195-bb12-4da5-ae3a-986352fc2dc4'
PROMPT_SHA = 'ee6caf0be6391e00ec41df930f0fd6351613969622cbb247b1b4bdaf69afe997'
PLAN_SHA = '8e1408f4f044b0fa6f97ae9b997d575797fe1d22036ddb68409e2aeb349949ed'
GIB = 1024 ** 3
MIB = 1024 ** 2
RETURNED = {'job.json', 'prompt.json', 'owner.json', 'resources.jsonl', 'terminal.json',
            'native/worker-0.stdin', 'native/worker-0.stdout', 'native/worker-0.stderr'}
RESOURCE_KEYS = set('startedMonotonicNS completedMonotonicNS timestampUTC actualFreeBytes '
                    'pressureLevel reportedSwapBytes acPower rawVMStat rawMemory rawPower'.split())


def require(value, message):
    if not value:
        raise ValueError(message)


def parse(raw):
    def pairs(rows):
        result = {}
        for key, value in rows:
            require(key not in result, 'Duplicate JSON field')
            result[key] = value
        return result
    def floating(value):
        result = float(value)
        require(math.isfinite(result), 'Nonfinite JSON number')
        return result
    def bad(_):
        raise ValueError('Nonfinite JSON constant')
    return json.loads(raw, object_pairs_hook=pairs, parse_float=floating, parse_constant=bad)


def canonical(value):
    return (json.dumps(value, sort_keys=True, separators=(',', ':'), allow_nan=False) + '\n').encode()


def digest(raw):
    return hashlib.sha256(raw).hexdigest()


def pin(raw):
    return dict(bytes=len(raw), sha256=digest(raw))


def identity(info):
    return (info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns, info.st_ctime_ns)


def integer(value, low=0, high=2**63-1):
    require(type(value) is int and low <= value <= high, 'Invalid bounded integer')
    return value


class Inputs:
    def __init__(self):
        self.saved = {}

    def read(self, path, cap=MIB):
        path = Path(path)
        require(path.is_absolute() and path.resolve() == path, 'Canonical input path required')
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        try:
            before = os.fstat(fd)
            require(stat.S_ISREG(before.st_mode) and 0 <= before.st_size <= cap, 'Bounded regular input required')
            with os.fdopen(fd, 'rb', closefd=False) as stream:
                raw = stream.read(cap + 1)
            after = identity(os.fstat(fd))
            require(identity(before) == after == identity(path.lstat()) and len(raw) == before.st_size,
                    'Input changed during read: ' + str(path))
            if str(path) in self.saved:
                require(self.saved[str(path)]['identity'] == after, 'Input changed between reads')
            self.saved[str(path)] = dict(**pin(raw), identity=after)
            return raw
        finally:
            os.close(fd)

    def recheck(self):
        for name, row in self.saved.items():
            require(identity(Path(name).lstat()) == row['identity'], 'Input changed after replay: ' + name)


def source_check(inputs):
    manifest = parse(inputs.read(HERE / 'manifest.json'))
    for name, expected in manifest['files'].items():
        require(Path(name).name == name, 'Unsafe helper member')
        require(pin(inputs.read(HERE / name)) == expected, 'Helper source changed: ' + name)
    authority = parse(inputs.read(HERE / 'source-pins.json'))
    for row in authority['files']:
        require(pin(inputs.read(Path(row['path']), 4*MIB)) == {k: row[k] for k in ('bytes', 'sha256')},
                'Reviewed source/input changed: ' + row['path'])
    prepared = parse(inputs.read(REFERENCE / 'manifest.json'))['files']
    require(type(prepared) is dict and len(prepared) <= 100, 'Prepared source closure bound')
    total = 0
    for name, expected in prepared.items():
        part = Path(name)
        require(not part.is_absolute() and '..' not in part.parts and str(part) == name, 'Unsafe prepared member')
        raw = inputs.read(REFERENCE / part, 4*MIB)
        require(pin(raw) == expected, 'Prepared reference source changed: ' + name)
        total += len(raw)
    require(total <= 4*MIB, 'Prepared reference closure exceeds 4 MiB')
    # These are fixed, reviewed pure parsers. No module from returned evidence is executed.
    sys.path.insert(0, str(PARSERS))
    contract = importlib.import_module('reference_contract')
    require(Path(contract.__file__).resolve() == PARSERS / 'reference_contract.py', 'Wrong contract import')
    return contract


def literal_assignment(raw, name):
    for node in ast.parse(raw).body:
        if isinstance(node, ast.Assign) and any(isinstance(t, ast.Name) and t.id == name for t in node.targets):
            value = ast.literal_eval(node.value)
            require(type(value) is str, 'Remote program must be literal text')
            return value
    raise ValueError('Missing remote program: ' + name)


def execution(inputs, reference, action, code):
    directory = reference / ('physical-' + action + '-1')
    receipt = parse(inputs.read(directory / 'execution.json'))
    expected = dict(action=action, passed=True, nativeRequested=action == 'run', exitCode=0,
                    reaped=True, groupAbsent=True, killedOwnedGroup=False,
                    timeoutSeconds=420 if action == 'run' else 45,
                    remoteCodeSHA256=digest(code.encode()))
    for name, wanted in expected.items():
        require(type(receipt.get(name)) is type(wanted) and receipt[name] == wanted,
                action + ' execution differs: ' + name)
    require(not any(k in receipt for k in ('failure', 'groupKillError', 'reapError', 'groupProbeError',
                                          'reapedBeforeExceptionCleanup', 'ownedGroupAlreadyAbsent')),
            action + ' execution retains a failure/cleanup exception')
    integer(receipt['pid'], 2)
    elapsed = receipt['elapsedSeconds']
    require(type(elapsed) in (int, float) and 0 <= elapsed < receipt['timeoutSeconds'], action + ' deadline exhausted')
    output = inputs.read(directory / 'stdout', 36*MIB if action == 'collect' else 131072)
    error = inputs.read(directory / 'stderr', 65536)
    require(receipt['stdout'] == pin(output) and receipt['stderr'] == pin(error) and not error,
            action + ' outer retained stream differs')
    return receipt, parse(output)


def raw_resource(value, phase=False):
    require(type(value) is dict and set(value) == RESOURCE_KEYS | ({'phase'} if phase else set()),
            'Resource record schema differs')
    if phase:
        require(value['phase'] in {'prelaunch', 'native-admitted', 'native-report', 'shutdown-wait',
                                   'completed-native', 'postflight'}, 'Unknown reference resource phase')
    for key in ('rawVMStat', 'rawMemory', 'rawPower'):
        require(type(value[key]) is str and len(value[key].encode()) <= 65536, 'Raw resource field bound')
    page = re.findall(r'page size of (\d+) bytes', value['rawVMStat'])
    free = re.findall(r'^Pages free:\s+(\d+)\.$', value['rawVMStat'], re.MULTILINE)
    swaps = re.findall(r'\bused\s*=\s*([0-9.]+)([MG])', value['rawMemory'])
    memory_lines = value['rawMemory'].splitlines()
    require(len(page) == len(free) == len(swaps) == 1 and page == ['16384']
            and memory_lines and memory_lines[0] == '1', 'Raw page/free/swap/pressure parse differs')
    actual = int(page[0]) * int(free[0])  # vm_stat free already excludes speculative pages.
    swap = Decimal(swaps[0][0]) * (MIB if swaps[0][1] == 'M' else GIB)
    require(integer(value['actualFreeBytes']) == actual and actual >= 6*GIB, 'Raw actual-free floor failed')
    require(integer(value['pressureLevel']) == 1 and type(value['reportedSwapBytes']) is str
            and swap == Decimal(value['reportedSwapBytes']) == 0, 'Raw pressure/swap differs')
    require(value['acPower'] is True and value['rawPower'].splitlines()[0] == "Now drawing from 'AC Power'",
            'Raw AC power differs')
    start, end = integer(value['startedMonotonicNS']), integer(value['completedMonotonicNS'])
    require(start <= end <= start + 10**10, 'Resource sampling exceeded 10 seconds')
    require(type(value['timestampUTC']) is str and len(value['timestampUTC']) <= 64
            and datetime.fromisoformat(value['timestampUTC']).utcoffset().total_seconds() == 0,
            'Resource UTC timestamp differs')
    return actual, start, end


def returned_files(inputs, reference, collection):
    require(type(collection) is dict and set(collection) == {'files', 'active', 'journalBytes'},
            'Collection packet schema differs')
    require(collection['active'] == [] and type(collection['journalBytes']) is int
            and collection['journalBytes'] == 0, 'Collection reports activity/nonempty journal')
    require(type(collection['files']) is list and len(collection['files']) == 8, 'Exactly eight returned files required')
    directory = reference / 'physical-collect-1/returned'
    require(directory.resolve() == directory and directory.is_dir(), 'Canonical returned directory required')
    actual_files, actual_dirs = set(), set()
    for parent, dirs, files in os.walk(directory, followlinks=False):
        for name in dirs + files:
            path = Path(parent) / name
            require(not path.is_symlink(), 'Returned tree contains a link')
        actual_dirs.update(str((Path(parent) / n).relative_to(directory)) for n in dirs)
        actual_files.update(str((Path(parent) / n).relative_to(directory)) for n in files)
    require(actual_files == RETURNED and actual_dirs == {'native'}, 'Returned tree differs from exact eight-file set')
    result, remote_identities = {}, {}
    for item in collection['files']:
        require(type(item) is dict and set(item) == {'path', 'bytes', 'sha256', 'identity', 'data'}, 'Collection file fields')
        name = item['path']
        require(type(name) is str and name in RETURNED and name not in result, 'Duplicate/unknown collection member')
        integer(item['bytes'], 0, 16*MIB)
        require(type(item['data']) is str and len(item['data']) <= 4*((16*MIB+2)//3), 'Collection base64 bound')
        raw = base64.b64decode(item['data'], validate=True)
        require(pin(raw) == {k: item[k] for k in ('bytes', 'sha256')}, 'Collection member hash/size differs')
        require(inputs.read(directory / name, 16*MIB) == raw, 'Returned member differs from collected bytes: ' + name)
        remote = item['identity']
        require(type(remote) is list and len(remote) == 5 and all(type(v) is int and v >= 0 for v in remote)
                and remote[2] == len(raw), 'Collection stat identity differs')
        result[name], remote_identities[name] = raw, remote
    require(set(result) == RETURNED and sum(map(len, result.values())) <= 24*MIB, 'Collected tree bound/set differs')
    return result, remote_identities


def native_terminal(raw, job, owner, contract, prompt):
    terminal = parse(raw['terminal.json'])
    expected_fields = set(('schema status jobSHA256 requestID sourceManifestSHA256 bundleSHA256 nativeSHA256 '
        'metallibSHA256 primaryFailure postflightErrors recordsAccepted sourceInputsUnchanged nativeLeaderReaped '
        'ownedGroupFenceComplete outputComplete independentNumericalComparisonPerformed independentPlanDerivationPerformed '
        'modelPayloadVerifiedByPython sourceToBinaryBuildIndependentlyVerified loadedMetallibIndependentlyVerified '
        'physicalTransferQualified throughputMeasurementValid descendantReapingIndependentlyProven owner '
        'requestFingerprint reportedPlanSHA256 selectedTokenIDsSHA256 nativeExitCodes cleanupErrors streams elapsedSeconds').split())
    require(type(terminal) is dict and set(terminal) == expected_fields, 'Terminal schema differs')
    wanted = dict(schema='private_full_generation_reference_terminal_v1', status='completed',
        jobSHA256=digest(raw['job.json']), requestID=job['request_id'], recordsAccepted=2,
        sourceInputsUnchanged=True, nativeLeaderReaped=True, ownedGroupFenceComplete=True,
        outputComplete=True, nativeExitCodes=[0], cleanupErrors=[], postflightErrors=[], primaryFailure=None,
        sourceManifestSHA256=job['source_manifest_sha256'], bundleSHA256=job['bundle_sha256'],
        nativeSHA256=job['native_sha256'], metallibSHA256=job['metallib_sha256'], owner=owner)
    for name, value in wanted.items():
        require(type(terminal.get(name)) is type(value) and terminal[name] == value, 'Native terminal differs: ' + name)
    for name in ('independentNumericalComparisonPerformed', 'independentPlanDerivationPerformed',
                 'modelPayloadVerifiedByPython', 'sourceToBinaryBuildIndependentlyVerified',
                 'loadedMetallibIndependentlyVerified', 'physicalTransferQualified',
                 'throughputMeasurementValid', 'descendantReapingIndependentlyProven'):
        require(terminal[name] is False, 'Unexpected expanded terminal claim: ' + name)
    require(all(type(code) is int for code in terminal['nativeExitCodes']), 'Invalid native exit type')
    require(type(terminal['elapsedSeconds']) in (int, float) and 0 <= terminal['elapsedSeconds'] < 315,
            'Native parent deadline exhausted')
    streams = terminal['streams']
    require(type(streams) is list and len(streams) == 3, 'Three retained native stream pins required')
    seen = set()
    for stream in streams:
        require(set(stream) == {'worker', 'stream', 'path', 'bytes', 'sha256'} and type(stream['worker']) is int
                and stream['worker'] == 0 and stream['stream'] in {'stdin', 'stdout', 'stderr'}
                and stream['stream'] not in seen, 'Retained native stream identity differs')
        seen.add(stream['stream'])
        name = 'native/worker-0.' + stream['stream']
        require(stream['path'] == str(Path(job['run_dir']) / name)
                and pin(raw[name]) == {k: stream[k] for k in ('bytes', 'sha256')}, 'Native stream hash/size/path differs')
    require(not raw['native/worker-0.stdin'] and not raw['native/worker-0.stderr'], 'Native stdin/stderr not empty')
    stdout = raw['native/worker-0.stdout']
    require(stdout.endswith(b'\n') and stdout.count(b'\n') == 2, 'Native requires exactly two complete JSON records')
    first_raw, final_raw = stdout[:-1].split(b'\n')
    expected = contract.expected_identity(job, prompt)
    first = contract.admitted(first_raw, expected)
    final = contract.report(final_raw, expected, first, owner['nativePID'], Path(job['deployment']))
    execution = final['execution']
    require(first['planSHA256'] == terminal['reportedPlanSHA256'] == PLAN_SHA
            and terminal['requestFingerprint'] == expected['requestFingerprint']
            and terminal['selectedTokenIDsSHA256'] == execution['selectedTokenIDsSHA256'], 'Native report/terminal identity differs')
    require(execution['completedFrames'] == 159 and execution['committedTokens'] == 8319
            and len(execution['selectedTokenIDs']) == 128 and execution['finishReason'] == 'length'
            and len(execution['finalState']['entries']) == 144, 'C256 completion/state count differs')
    return terminal, final


def review(inputs, facts):
    contract = source_check(inputs)
    runner = inputs.read(REFERENCE / 'run_physical.py')
    job_raw = inputs.read(INPUTS / 'reference-job.json', 16384)
    prompt_raw = inputs.read(INPUTS / 'prompt.ids.json', 65536)
    job, prompt = parse(job_raw), parse(prompt_raw)
    require(job_raw == canonical(job) == inputs.read(REFERENCE / 'package/example-job.json', 16384), 'Prospective job differs')
    require(prompt_raw == inputs.read(REFERENCE / 'package/prompt.ids.json', 65536)
            and digest(prompt_raw) == PROMPT_SHA == job['prompt_sha256'], 'Prospective prompt differs')
    require(type(prompt) is list and len(prompt) == 8192
            and all(type(v) is int and 0 <= v < 248320 for v in prompt), 'Bounded prompt tokens differ')
    require((job['request_id'], job['registered_model'], job['stage_cut'], job['prompt_count'], job['chunk_size'],
             job['output_count'], job['stop_token_ids'], job['native_seconds'], job['parent_seconds'])
            == (REQUEST, 'registered_qwen38_27b', 16, 8192, 256, 128, [], 300, 315), 'Wrong C256 request')
    copy, copied = execution(inputs, REFERENCE, 'copy', inputs.read(REFERENCE / 'install_new_tree.py').decode())
    deployment_raw = inputs.read(REFERENCE / 'deployment.json')
    deployment = parse(deployment_raw)
    require(copy['verifiedFiles'] == 65 and copied['manifestSHA256'] == digest(deployment_raw)
            and copied['verified'] == {name: {k: row[k] for k in ('bytes', 'sha256')}
                                        for name, row in deployment['files'].items()}
            and len(copied['verified']) == 65 and copied['modelOrOwnerLaunched'] is False
            and copied['existingInputsModified'] is False, 'Copy-only deployment proof differs')
    run, preflight = execution(inputs, REFERENCE, 'run', literal_assignment(runner, 'REMOTE_RUN'))
    collect, packet = execution(inputs, REFERENCE, 'collect', literal_assignment(runner, 'REMOTE_COLLECT'))
    require(collect['verifiedFiles'] == 8 and collect['active'] == packet['active'] == []
            and type(collect['journalBytes']) is int and collect['journalBytes'] == packet['journalBytes'] == 0,
            'Collection terminal differs')
    require(set(preflight) == {'kind', 'active', 'journalBytes', 'resource'}
            and preflight['kind'] == 'root_cut16_reference_preflight' and preflight['active'] == []
            and type(preflight['journalBytes']) is int and preflight['journalBytes'] == 0, 'Preflight differs')
    preflight_free, _, _ = raw_resource(preflight['resource'])
    facts['outerExecutions'] = {name: dict(exitCode=row['exitCode'], reaped=row['reaped'], groupAbsent=row['groupAbsent'],
        killedOwnedGroup=row['killedOwnedGroup'], elapsedSeconds=row['elapsedSeconds'])
        for name, row in [('copy', copy), ('run', run), ('collect', collect)]}
    returned, remote_identities = returned_files(inputs, REFERENCE, packet)
    facts['returnedFiles'] = {name: pin(raw) for name, raw in sorted(returned.items())}
    facts['remoteCollectedIdentities'] = remote_identities
    require(returned['job.json'] == job_raw and returned['prompt.json'] == prompt_raw, 'Actual request packet differs')
    owner = parse(returned['owner.json'])
    require(type(owner) is dict and set(owner) == set('nativePID nativePGID supervisorPID nativeArgv nativeEnvironment nativeSeconds parentSeconds'.split()),
            'Owner schema differs')
    require(integer(owner['nativePID'], 2) == integer(owner['nativePGID'], 2)
            and integer(owner['supervisorPID'], 2) != owner['nativePID'], 'Native owner PID/PGID differs')
    argv = [str(Path(job['deployment']) / 'cluster-inference'), '--mode', 'qwen-registered-full-generation-reference',
        '--model-dir', job['model_dir'], '--tokens-file', str(Path(job['run_dir']) / 'prompt.json'),
        '--tokens-sha256', job['prompt_sha256'], '--request-id', job['request_id'], '--stage-cut', '16',
        '--output-count', '128', '--stop-token-ids', '[]', '--registered-dense-profile', 'registered_qwen38_27b',
        '--prompt-count', '8192', '--chunk-size', '256', '--timeout-seconds', '300']
    environment = dict(PATH='/usr/bin:/bin:/usr/sbin:/sbin', LANG='C', DARKBLOOM_BF16_WEIGHTS='1',
                       DARKBLOOM_CBV2_ATTN_QUERY_BLOCK='128', MLX_ENABLE_TF32='1')
    require(owner['nativeArgv'] == argv and owner['nativeEnvironment'] == environment
            and type(owner['nativeSeconds']) is int and owner['nativeSeconds'] == 300
            and type(owner['parentSeconds']) is int and owner['parentSeconds'] == 315, 'Actual native invocation differs')
    terminal, final = native_terminal(returned, job, owner, contract, prompt)
    facts['nativeLifecycle'] = {key: terminal[key] for key in ('status', 'nativeExitCodes', 'nativeLeaderReaped',
        'ownedGroupFenceComplete', 'outputComplete', 'sourceInputsUnchanged', 'cleanupErrors', 'postflightErrors', 'elapsedSeconds')}
    facts['nativePID'] = owner['nativePID']
    resources_raw = returned['resources.jsonl']
    require(resources_raw.endswith(b'\n'), 'Resources lack final LF')
    rows = [parse(line) for line in resources_raw.splitlines()]
    require(4 <= len(rows) <= 2000 and rows[0]['phase'] == 'prelaunch' and rows[-1]['phase'] == 'postflight', 'Resource endpoint/count differs')
    phases = Counter(row['phase'] for row in rows)
    require(phases['prelaunch'] == 3 and phases['postflight'] == 1, 'Expected three prelaunch samples and one postflight')
    values, previous_end = [], -1
    for row in rows:
        actual, start, end = raw_resource(row, phase=True)
        require(start >= previous_end, 'Resource sampling chronology regressed within the supervisor')
        values.append(actual)
        previous_end = end
    execution_report = final['execution']
    facts['rawResources'] = dict(sampleCount=len(rows), preflightSampleCount=1, phases=dict(phases),
        minimumActualFreeBytes=min(values), minimumIncludingOuterPreflightBytes=min(values + [preflight_free]),
        firstActualFreeBytes=values[0], lastActualFreeBytes=values[-1], allRawPressureExactlyOne=True,
        allRawSwapZero=True, allRawACPower=True, actualFreeFloorBytes=6*GIB, allActualFreeAtLeastFloor=True,
        firstTimestampUTC=rows[0]['timestampUTC'], lastTimestampUTC=rows[-1]['timestampUTC'])
    facts['nativeResourceSummary'] = {key: final['resources'][key] for key in ('observationCount',
        'minimumActualFreeBytes', 'maximumObservedActiveBytes', 'wholeProcessPeakBoundEstablished')}
    facts['requestContract'] = dict(requestID=job['request_id'], requestFingerprint=terminal['requestFingerprint'],
        planSHA256=PLAN_SHA, promptCount=8192, chunkSize=256, outputCount=128, completedFrames=159,
        committedTokens=8319, finalStateEntries=144, mtpEnabled=False, finishReason=execution_report['finishReason'],
        selectedTokenIDs=execution_report['selectedTokenIDs'], selectedTokenIDsSHA256=terminal['selectedTokenIDsSHA256'],
        finalStateFingerprint=execution_report['finalState']['fingerprint'],
        finalLogitsSHA256=execution_report['finalLogits']['logicalBytesSHA256'], referenceSHA256=digest(returned['native/worker-0.stdout']))
    facts['observedCollectionState'] = dict(activeProcesses=packet['active'], journalBytes=packet['journalBytes'])


def main():
    parser = argparse.ArgumentParser(allow_abbrev=False)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    require(args.output.is_absolute() and args.output.parent.resolve() == args.output.parent,
            'Output needs an existing canonical parent')
    require(not args.output.exists() and not args.output.is_symlink(), 'Output must be create-only')
    require(REFERENCE not in args.output.parents and INPUTS not in args.output.parents, 'Output may not enter input/evidence trees')
    inputs, facts = Inputs(), {}
    result = dict(schema='c256_reference_independent_findings_v1', evidenceReplayCompleted=False,
        requiresIndependentRootReview=True, qualificationGranted=False, launchedChildProcesses=False, facts=facts,
        limitations=[
            'No passed field: this is not the root approval consumed by bind_reference.py.',
            'Journal size and filtered process absence are collection observations; no collection-time journal inode or held-lock receipt exists.',
            'Native natural exit, reap, EOF and group fence are separate recorded supervisor proofs; descendant reaping is not independently proven.',
            'Native 300-second and parent 315-second limits are source/invocation bound; the terminal has no explicit watchdog-armed/fired field.',
            'Raw OS samples are discrete observations, not continuous whole-process peak or future placement guarantees.',
            'Resource monotonic ordering is checked only within resources.jsonl; no cross-process or cross-host clock subtraction is performed.',
            'The unchanged reference contract validates request, final row shape and state metadata/digest coverage; it is not an independent numerical oracle.',
            'Remote native/model/source hashes are joined to pinned metadata and sourceInputsUnchanged; this helper does not read live hosts or rehash binaries/models.',
            'No throughput, encrypted transfer, candidate comparison, new serving eligibility or 24/40 placement qualification is granted.'])
    try:
        review(inputs, facts)
        inputs.recheck()
        result['evidenceReplayCompleted'] = True
    except Exception as error:
        result['failure'] = dict(type=type(error).__name__, message=str(error)[:2048])
    result['readInputs'] = inputs.saved
    encoded = canonical(result)
    require(len(encoded) <= 512*1024, 'Findings exceeded 512 KiB bound')
    fd = os.open(args.output, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, 'wb') as stream:
        stream.write(encoded)
    print(json.dumps(dict(output=str(args.output), **pin(encoded), evidenceReplayCompleted=result['evidenceReplayCompleted'],
                          requiresIndependentRootReview=True), sort_keys=True))
    return 0 if result['evidenceReplayCompleted'] else 1


if __name__ == '__main__':
    os.umask(0o077)
    raise SystemExit(main())
