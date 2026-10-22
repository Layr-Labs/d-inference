"""Read-only replay of the retained configured-deadline observation.

Uses no client/harness imports and performs no network, process or model work.
Writes its result only to stdout. This is a post-observation consistency review.
"""
from pathlib import Path
from decimal import Decimal
import hashlib
import json
import re

BASE = Path('/Users/developer/DarkbloomDev/cluster-research/installed-http-configured-deadline-qualification-20260915')
PHYSICAL = BASE / 'harness/physical-1'
TRANSACTION = BASE / 'transactions/attempt-1'
EMPTY = hashlib.sha256(b'').hexdigest()
pins = {}


def raw(path, cap=2_000_000):
    value = path.read_bytes()
    assert len(value) <= cap, str(path)
    pins[str(path)] = hashlib.sha256(value).hexdigest()
    return value


def unique(pairs):
    result = {}
    for key, value in pairs:
        assert key not in result, key
        result[key] = value
    return result


def decode(value):
    return json.loads(value, object_pairs_hook=unique,
                      parse_constant=lambda x: (_ for _ in ()).throw(ValueError(x)))


def read(path):
    return decode(raw(path))


manifest = read(BASE / 'manifest.json')
assert pins[str(BASE / 'manifest.json')] == 'b130dc4d007b4f699cb56712b954d00ede0a8e91db7c20094a1a25f6a63d9c19'
for member in manifest['members']:
    value = raw(BASE / member['path'])
    assert len(value) == member['bytes'] and hashlib.sha256(value).hexdigest() == member['sha256']
for name, expected in read(PHYSICAL / 'input-pins.json').items():
    assert hashlib.sha256(raw(Path(name))).hexdigest() == expected

client = read(PHYSICAL / 'client/receipt.json')
wire = raw(PHYSICAL / 'client/response.sse')
assert hashlib.sha256(wire).hexdigest() == client['response_sha256']
assert len(wire) == client['captured_response_bytes'] == 448
assert hashlib.sha256(raw(PHYSICAL / 'client/request.json')).hexdigest() == client['request_sha256']
request = read(PHYSICAL / 'client/request.json')
assert request['model'] == 'Qwen3.5-9B' and request['stream'] is True and request['max_tokens'] == 128
arrivals = [decode(line) for line in raw(PHYSICAL / 'client/arrivals.jsonl').splitlines()]
offset = previous_time = 0
for arrival in arrivals:
    assert set(arrival) == {'offset', 'bytes', 'elapsed_ns'}
    assert all(type(value) is int for value in arrival.values())
    assert arrival['offset'] == offset and arrival['bytes'] > 0
    assert previous_time <= arrival['elapsed_ns'] <= 90_000_000_000
    offset += arrival['bytes']; previous_time = arrival['elapsed_ns']
assert offset == len(wire) and wire.endswith(b'\n\n')
frames, cursor = [], 0
for block in wire.split(b'\n\n')[:-1]:
    cursor += len(block) + 2
    received = next(x['elapsed_ns'] for x in arrivals if x['offset'] + x['bytes'] >= cursor)
    frames.append((block, received))
assert len(frames) == 6
assert frames[1:4] and all(value == b': keep-alive' for value, _ in frames[1:4])
role = decode(frames[0][0].removeprefix(b'data: '))
assert role['choices'] == [{'delta': {'role': 'assistant'}, 'index': 0}]
terminal = decode(frames[4][0].removeprefix(b'data: '))
assert terminal == {
    'attempt_usage': {'completion_tokens': 0, 'prompt_tokens': 8192},
    'error': {'code': 'inference_error', 'message': 'Distributed generation did not complete',
              'terminal_cause': 'safety_deadline', 'type': 'server_error'},
}
assert frames[5][0] == b'data: [DONE]'
assert client['http_status'] == 200 and client['status'] == 'failed'
assert client['capture_complete'] is True and client['http_body_eof_observed'] is True
assert frames[-1][1] <= client['http_body_eof_received_ns'] < 90_000_000_000
measurement = client['measurement']
assert measurement['typed_error_received_ns'] == frames[4][1] == 2_144_623_750
assert measurement['typed_error'] == terminal['error'] and measurement['attempt_usage'] == terminal['attempt_usage']
assert measurement['first_content_ns'] is None and measurement['text_events'] == 0
assert measurement['done'] is True and measurement['failure_terminal_complete'] is True
assert measurement['stream_terminal_complete'] is False and measurement['usage'] is None
for sla in measurement['content_sla'].values():
    assert sla['deadline_ns'] == 18_192_000_000 and sla['request_passed'] is False

physical = read(PHYSICAL / 'execution.json')
assert physical['clientExitCode'] == 1 and physical['supervisorExitCode'] == 1
assert physical['inferenceRequestSucceeded'] is False and physical['slaPassed'] is False
assert physical['configuredRequestTimeoutSeconds'] == 2 and physical['naturalContentDeadlineMissReproduced'] is False
assert not any(key in physical for key in ['parentStopIssued', 'error', 'supervisorCleanupError'])
assert physical['guardErrors'] == physical['postflightObservationErrors'] == []
assert physical['monitors'] == [{'exitCode': 0, 'errors': []}] * 2
assert physical['clientReceiptSHA256'] == pins[str(PHYSICAL / 'client/receipt.json')]
supervisor = read(PHYSICAL / 'supervisor.json')
assert supervisor['forcedKill'] is False and supervisor['stopReason'] == 'natural-exit' and supervisor['exitCode'] == 1
assert read(PHYSICAL / 'self-retirement-files/0-supervisor.json') == supervisor
assert raw(PHYSICAL / 'self-retirement-files/0-provider.stderr') == raw(PHYSICAL / 'provider.stderr')
assert raw(PHYSICAL / 'self-retirement-files/0-provider.stdout') == raw(PHYSICAL / 'provider.stdout')
retirement = physical['selfRetirement']
assert retirement['self_retirement_observed'] is True and retirement['harness_interference_observed'] is False
assert len(retirement['samples']) == 1 and len(retirement['samples'][0]['nodes']) == 2
for node in retirement['samples'][0]['nodes'] + physical['postflight']:
    assert node == {'active': [], 'journalBytes': 0, 'journalSHA256': EMPTY}
assert retirement['elapsed_after_client_close_seconds'] < 1
log = raw(PHYSICAL / 'provider.stderr').decode()
lifecycle = []
for line in log.splitlines():
    if 'Distributed request lifecycle' not in line:
        continue
    values = dict(re.findall(r'(\w+)=([^ ]+)', line))
    assert values['completion_tokens'] == '0' and values['prompt_tokens'] == '8192'
    assert values['dropped_observations'] == '0'
    lifecycle.append(values)
assert [x['phase'] for x in lifecycle] == ['reserved', 'terminal', 'retired']
assert len({x['generation'] for x in lifecycle}) == 1
assert all(x.get('outcome') == 'safety_deadline' for x in lifecycle[1:])
times = [Decimal(x['admission_elapsed_ms']) for x in lifecycle]
assert times == sorted(times)

resource_summary = []
for rank in range(2):
    rows = [decode(line) for line in raw(PHYSICAL / ('resources-%d.jsonl' % rank)).splitlines()]
    assert len(rows) == [43, 39][rank]
    previous_start = 0
    for ordinal, value in enumerate(rows):
        assert value['ordinal'] == ordinal and value['admissible'] is True and 'error' not in value
        start, end = value['startedMonotonicNS'], value['completedMonotonicNS']
        assert previous_start <= start <= end and end - start <= 10_000_000_000
        previous_start = start
        page = re.findall(r'page size of (\d+) bytes', value['rawVMStat'])
        free = re.findall(r'^Pages free:\s+(\d+)\.$', value['rawVMStat'], re.M)
        assert len(page) == len(free) == 1
        actual = int(page[0]) * int(free[0])
        assert type(value['actualFreeBytes']) is int and actual == value['actualFreeBytes'] and actual >= 6 * 1024**3
        pressure = value['rawMemory'].splitlines()[0]
        assert pressure.isdigit() and int(pressure) == value['pressureLevel'] == 1
        swap = re.findall(r'used\s*=\s*([0-9.]+)([MG])', value['rawMemory'])
        assert len(swap) == 1 and Decimal(swap[0][0]) == Decimal(value['reportedSwapBytes']) == 0
        assert "Now drawing from 'AC Power'" in value['rawPower'] and value['acPower'] is True
    assert raw(PHYSICAL / ('resources-%d.stderr' % rank)) == b''
    minimum = min(x['actualFreeBytes'] for x in rows)
    resource_summary.append({'rank': rank, 'sampleCount': len(rows), 'minimumActualFreeBytes': minimum,
                             'minimumActualFreeGiB': minimum / 1024**3,
                             'maximumStartGapNanoseconds': max(b['startedMonotonicNS'] - a['startedMonotonicNS'] for a, b in zip(rows, rows[1:]))})

status = read(PHYSICAL / 'status-before.stdout.json')
status_receipt = read(PHYSICAL / 'status-before.receipt.json')
assert status_receipt['stdoutSHA256'] == pins[str(PHYSICAL / 'status-before.stdout.json')]
assert status_receipt['localExitCode'] == 0 and raw(PHYSICAL / 'status-before.stderr') == b''
live = status['live']; session = live['session']; binding = live['binding']
assert live['authenticationConfigured'] is True and live['ready'] is True and session['ready'] is True
assert binding == session['binding'] == status['saved'] == physical['statusBefore']['binding']
assert binding['prefillSchedule'] == session['observedPrefillSchedule'] == 'one_chunk_lookahead_v1'
assert binding['clusterID'] == 'darkbloom-product-qwen9b-configured-deadline-20260915'
assert session['mtpEnabled'] is False and session['mtpOffReason'] == 'runtimeCapabilityDisablesSpeculation'
assert session['admission']['remainingRequests'] == 16 and session['admission']['activeRequest'] is False
assert [m['rank'] for m in session['members']] == [0, 1] and all(m['nativeReady'] for m in session['members'])
assert [m['transport'] for m in session['members']] == ['localPipes', 'authenticatedSSH']
assert live['nonce'] == physical['statusBefore']['nonce'] == status_receipt['validation']['nonce']
ids = read(BASE.parent / 'installed-http-long-prompts-20260915/fixtures/prompt-8192.ids.json')
tokenizer = read(PHYSICAL / 'tokenizer-response.json')
assert tokenizer['tokens'] == ids and len(ids) == 8192 and all(type(x) is int for x in ids)

transaction = read(TRANSACTION / 'execution.json')
assert transaction['physical']['receiptSHA256'] == pins[str(PHYSICAL / 'execution.json')]
assert transaction['qualified'] is True and transaction['defaultsRestored'] is True
assert transaction['error'] is None and transaction['restorationErrors'] == transaction['recoveryReceiptErrors'] == {}
assert transaction['configuredRequestTimeoutSeconds'] == 2 and transaction['ordinaryRequestTimeoutSeconds'] == 120
restored = []
for host, before, role in [
    ('darkbloom-24', 'dea0e291200e111d0fbc5f8e549db5054546aeeaf963a854519804e3c5c675d6', 'leader'),
    ('darkbloom-48', '47c083ac6eb0d7926b4bd468437e3d6dea1dc92e9bc44e63a133c4cc907f941e', 'follower'),
]:
    values = {}
    for action in ['prepare', 'install', 'restore']:
        path = TRANSACTION / (host + '.' + action)
        stdout = raw(path.with_name(path.name + '.stdout.json'))
        stderr = raw(path.with_name(path.name + '.stderr'))
        receipt = read(path.with_name(path.name + '.receipt.json'))
        assert receipt['exitCode'] == 0 and stderr == b''
        assert receipt['stdoutSHA256'] == hashlib.sha256(stdout).hexdigest() and receipt['stderrSHA256'] == EMPTY
        assert receipt['remoteProgramSHA256'] == 'a9b287b47a01670e6b55ed6c11ca2d69fbb2b04101862b75ea5fb837465873c7'
        values[action] = decode(stdout)
        assert values[action] == transaction[{'prepare': 'prepared', 'install': 'installed', 'restore': 'restored'}[action]][host]
        assert values[action]['mode'] == 0o600
        assert receipt['postimageSHA256'] == (None if action == 'prepare' else values['prepare']['afterSHA256'])
    preparation = values['prepare']; installation = values['install']; restoration = values['restore']
    assert preparation['beforeSHA256'] == restoration['providerSHA256'] == before
    assert preparation['afterSHA256'] == installation['providerSHA256']
    assert preparation['configurationSHA256'] == hashlib.sha256(raw(BASE / ('configuration/' + role + '.configure.json'))).hexdigest()
    assert preparation['defaultChanged'] is False and preparation['memberID'] == host
    assert installation['installed'] is True and restoration['restored'] is True
    restored.append({'memberID': host, 'beforeAndRestoredSHA256': before, 'temporarySHA256': preparation['afterSHA256'], 'mode': '0600'})
alias = physical['aliasCleanup']['final'][0]
assert physical['aliasCleanup']['exitCode'] == 0 and alias['restored'] is True
assert alias['before']['en1'] == alias['afterRemove']['en1']
assert alias['before']['gid'] == alias['afterRemove']['gid']
assert '169.254.70.47' not in alias['afterRemove']['en1'] and '169.254.70.47' not in alias['afterRemove']['gid']
assert alias['before']['managementRoute'] == alias['afterRemove']['managementRoute']
assert re.findall(r'member: (\w+)', alias['before']['bridge0']) == re.findall(r'member: (\w+)', alias['afterRemove']['bridge0'])

print(json.dumps({
    'schema': 'configured_deadline_evidence_review_v1', 'result': 'passed for the bounded configured-deadline observation',
    'method': 'Independent raw SSE delimiter/arrival replay, raw vm_stat/sysctl/pmset recomputation, source/receipt joins and retained lifecycle/restoration observation checks. No client or harness validator imports.',
    'client': {'httpStatus': 200, 'status': 'failed', 'rawBytes': len(wire), 'arrivalRecords': len(arrivals),
               'roleEvents': 1, 'keepaliveComments': 3, 'typedErrorEvents': 1, 'doneEvents': 1,
               'typedErrorDelimiterNanoseconds': frames[4][1], 'doneDelimiterNanoseconds': frames[5][1],
               'bodyEOFNanoseconds': client['http_body_eof_received_ns'], 'contentEvents': 0,
               'attemptUsage': terminal['attempt_usage'], 'error': terminal['error'],
               'inferenceRequestSucceeded': False, 'originalContentSLAPassed': False,
               'originalContentSLANanoseconds': 18_192_000_000, 'configuredDeadlineNanoseconds': 2_000_000_000},
    'lifecycle': {'requestID': lifecycle[0]['generation'], 'phases': [x['phase'] for x in lifecycle],
                  'engineAdmissionElapsedMilliseconds': [str(x) for x in times],
                  'retiredAfterTerminalMilliseconds': str(times[2] - times[1]),
                  'droppedObservations': 0, 'naturalCLIExitCode': 1, 'forcedKill': False,
                  'parentStopIssued': False, 'absentWorkersAndEmptyJournalsObservedAfterClientCloseSeconds': retirement['elapsed_after_client_close_seconds']},
    'resources': resource_summary, 'configurationRestoration': restored,
    'membershipEpoch': session['observedMembershipEpoch'], 'configuredHTTPAuthenticationObserved': True,
    'aliasRestorationObserved': True,
    'limits': ['Configured two-second negative test, not reproduction of a natural 18.192-second content miss.',
               'Attempt usage agrees with actual tokenizer IDs and Provider logs; no independent native tensor or committed-token audit.',
               'Retirement combines the Provider event, natural CLI exit and process/journal observations. Separate per-rank ACK transcripts are not retained.',
               'Configuration restoration is verified from captured command/readback receipts. Remote backup files were not reread by this reviewer.',
               'Periodic samples do not prove the continuous minimum or unknown native workspace peak.',
               'Client and engine admission elapsed clocks are kept separate; no cross-host uptime subtraction.',
               'No model correctness, throughput, OpenRouter, general failure recovery or release qualification.'],
    'reviewExecution': {'remote': False, 'native': False, 'compiler': False, 'fixtureRerun': False, 'frozenEvidenceModified': False},
    'inputPins': pins,
}, indent=2))
