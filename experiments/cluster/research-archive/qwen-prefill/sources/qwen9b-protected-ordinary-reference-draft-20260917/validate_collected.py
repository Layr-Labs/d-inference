"""Join an actual launched reference to its exact collected evidence."""
from pathlib import Path
import sys

BASE = Path(__file__).resolve().parent
sys.path.insert(0, str(BASE / 'package'))
from binding_common import parse, require, same
from binding_inputs import snapshot
from mtp_journal import require_empty
from reference_contract import admitted, expected_identity, report
from reference_resources import validate_local
from reference_settings import REMOTE

EXPECTED = {'job.json', 'prompt.json', 'resources.jsonl', 'journal-before.json', 'processes-before.json',
            'launch.json', 'gate.json', 'owner.json', 'native/worker-0.stdin', 'native/worker-0.stdout',
            'native/worker-0.stderr', 'physical-postflight.json', 'terminal.json'}


def validate(directory, header, launch_receipt, binding, expected_job):
    same({r['path'] for r in header['files']}, EXPECTED, 'Complete reference evidence membership')
    same(header['remoteRoot'], str(REMOTE / 'runs/reference-1'), 'Reference collection namespace')
    same(header['mode'], 'reference', 'Reference mode'); same(header['attempt'], 1, 'Reference attempt')
    same(snapshot(directory / 'terminal.json', 1024**2)['sha256'], launch_receipt['terminalSHA256'], 'Launch-to-collection terminal hash')
    job = parse(snapshot(directory / 'job.json', 16384)['raw']); same(job, expected_job, 'Collected job')
    same(snapshot(directory / 'job.json', 16384)['sha256'], binding['jobSHA256'], 'Collected job pin')
    prompt = snapshot(directory / 'prompt.json', 65536); same(prompt['sha256'], binding['promptSHA256'], 'Actual prompt pin')
    terminal = parse(snapshot(directory / 'terminal.json', 1024**2)['raw'])
    for key, value in dict(status='completed', recordsAccepted=2, sourceInputsUnchanged=True,
                           nativeLeaderReaped=True, ownedGroupFenceComplete=True, outputComplete=True,
                           nativeExitCodes=[0], postflightErrors=[], cleanupErrors=[]).items():
        same(terminal.get(key), value, 'Terminal ' + key)
    same(terminal['jobSHA256'], binding['jobSHA256'], 'Terminal job pin')
    raw = snapshot(directory / 'native/worker-0.stdout', 32*1024**2)['raw']
    rows = raw.splitlines(); require(len(rows) == 2 and raw.endswith(b'\n'), 'Exactly two native reference records')
    expected = expected_identity(job, parse(prompt['raw']))
    first = admitted(rows[0], expected)
    owner = parse(snapshot(directory / 'owner.json', 16384)['raw'])
    final = report(rows[1], expected, first, owner['nativePID'], Path(job['deployment']))
    require(snapshot(directory / 'native/worker-0.stderr', 1, empty=True)['raw'] == b'', 'Native stderr is not empty')
    require(snapshot(directory / 'native/worker-0.stdin', 1, empty=True)['raw'] == b'', 'Reference received unexpected stdin')
    gate = parse(snapshot(directory / 'gate.json', 65536)['raw'])
    same(gate['ownerPID'], owner['nativePID'], 'Gate and actual native PID')
    for key, value in dict(exclusiveLockHeld=True, inheritedAcrossExec=True, journalMutationPerformed=False, protocolReleaseACK=False).items():
        same(gate[key], value, 'Inherited gate ' + key)
    before = parse(snapshot(directory / 'journal-before.json', 16384)['raw'])
    after = parse(snapshot(directory / 'physical-postflight.json', 65536)['raw'])
    same(after['inheritedGateObserved'], True, 'Actual inherited gate postflight')
    same(after['protocolReleaseACK'], False, 'Reference exclusion is not a protocol release')
    require_empty(before); require_empty(after['journal'], before); require_empty(after['journal'], gate)
    require_empty(header['observation']['journal'], before)
    require(not after['processes']['prohibited'] and not header['observation']['active'], 'A native/owner remains')
    resource_rows = snapshot(directory / 'resources.jsonl', 4*1024**2)['raw'].splitlines()
    require(3 <= len(resource_rows) <= 2000, 'Retained actual resource sample coverage')
    for row in resource_rows:
        validate_local(parse(row))
    execution = final['execution']
    same(execution['completedFrames'], 3, 'Two prefill frames plus one decode')
    same(execution['committedTokens'], 33, 'Accepted input frontier')
    same(execution['maximumTokens'], 34, 'State capacity')
    same(len(execution['selectedTokenIDs']), 2, 'Actual selected output count')
    return dict(schema='qwen9b_protected_ordinary_reference_result_v1', requestID=job['request_id'],
        promptSHA256=binding['promptSHA256'], artifactSHA256=execution['source']['artifactAggregateSHA256'],
        nativeSHA256=job['native_sha256'], terminalSHA256=launch_receipt['terminalSHA256'],
        selectedTokenIDs=execution['selectedTokenIDs'], selectedTokenIDsSHA256=execution['selectedTokenIDsSHA256'],
        finalLogitsSHA256=execution['finalLogits']['logicalBytesSHA256'],
        finalStateFingerprint=execution['finalState']['fingerprint'], stateEntries=len(execution['finalState']['entries']),
        referenceCompleted=True, protectedPairCompared=False, physicalTransferQualified=False, servingEnabled=False)
