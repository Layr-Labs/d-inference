"""Retrospective CPU replay of two retained HTTP attempts; no imported producer code."""
import hashlib
import json
from pathlib import Path
import re
from decimal import Decimal

ROOT = Path('/Users/developer/DarkbloomDev/cluster-research')
HERE = Path(__file__).resolve().parent
HARNESS = ROOT / 'installed-product-http-qualification-20260915'
CLIENT = ROOT / 'installed-http-client-draft-20260915'
INPUTS = {}


def sha(raw):
    return hashlib.sha256(raw).hexdigest()


def read(path):
    raw = path.read_bytes()
    INPUTS[str(path.relative_to(ROOT))] = dict(bytes=len(raw), sha256=sha(raw))
    return raw


def unique(pairs):
    result = {}
    for key, value in pairs:
        assert key not in result, 'Duplicate JSON key'
        result[key] = value
    return result


def decode(raw):
    return json.loads(raw, object_pairs_hook=unique,
                      parse_constant=lambda value: (_ for _ in ()).throw(ValueError(value)))


def doc(path):
    return decode(read(path))


def integer(value, lower=0):
    assert type(value) is int and value >= lower
    return value


def resources(path):
    raw = read(path)
    assert raw.endswith(b'\n')
    rows = [decode(line) for line in raw.splitlines()]
    assert 1 <= len(rows) <= 1400
    previous = 0
    free, gaps, durations = [], [], []
    for i, row in enumerate(rows):
        assert row['ordinal'] == i and row['schema'] == 'native_owner_resource_observation_v1'
        start, end = integer(row['startedMonotonicNS']), integer(row['completedMonotonicNS'])
        assert previous <= start <= end and end-start <= 10_000_000_000
        if i:
            gaps.append(start-previous)
        previous = end
        durations.append(end-start)
        page = int(re.search(r'page size of (\d+) bytes', row['rawVMStat'])[1])
        pages = int(re.search(r'^Pages free:\s+(\d+)\.$', row['rawVMStat'], re.M)[1])
        actual = page * pages
        assert page == 16384 and actual == integer(row['actualFreeBytes']) and actual >= 6*1024**3
        pressure = int(row['rawMemory'].splitlines()[0])
        swap = re.search(r'\bused\s*=\s*([0-9.]+)([MG])', row['rawMemory'])
        swap_bytes = Decimal(swap[1]) * (1024**2 if swap[2] == 'M' else 1024**3)
        assert swap_bytes == Decimal(row['reportedSwapBytes']) == 0
        assert pressure == row['pressureLevel'] == 1
        assert "Now drawing from 'AC Power'" in row['rawPower']
        assert row['acPower'] is True and row['admissible'] is True and 'error' not in row
        free.append(actual)
    return dict(samples=len(rows), minimumActualFreeBytes=min(free),
                minimumActualFreeGiB=min(free)/1024**3, pageBytes=16384,
                allObservedPressureLevel1=True, allObservedSwapBytesZero=True,
                allObservedAC=True, maximumSampleDurationNS=max(durations),
                maximumInterSampleGapNS=max(gaps), continuousResourceProof=False)


def stream(path, receipt):
    raw = read(path / 'response.sse')
    arrivals = [decode(line) for line in read(path / 'arrivals.jsonl').splitlines()]
    lines = raw.splitlines(keepends=True)
    assert len(arrivals) == len(lines) <= 4096 and raw.endswith(b'\n\n')
    assert sha(raw) == receipt['response_sha256'] and len(raw) == receipt['captured_response_bytes']
    offset = previous = 0
    events, pending = [], []
    for line, arrival in zip(lines, arrivals):
        assert set(arrival) == {'offset', 'bytes', 'elapsed_ns'}
        assert integer(arrival['offset']) == offset and integer(arrival['bytes'], 1) == len(line)
        clock = integer(arrival['elapsed_ns'])
        assert previous <= clock
        offset += len(line)
        previous = clock
        if line in (b'\n', b'\r\n'):
            assert len(pending) == 1  # Exact observed producer framing, not a general SSE parser.
            events.append((pending.pop(), clock))
        else:
            assert line.startswith(b'data: ') and line.endswith(b'\n')
            pending.append(line[6:].rstrip(b'\r\n').decode('utf8'))
    assert not pending and offset == len(raw)
    assert events[-1][0] == '[DONE]' and all(x[0] != '[DONE]' for x in events[:-1])
    identity = None
    contents, reasonings, usage, finish = [], [], [], []
    for i, (payload, clock) in enumerate(events[:-1]):
        item = decode(payload)
        assert item['object'] == 'chat.completion.chunk' and item['model'] == receipt['model']
        identity = item['id'] if identity is None else identity
        assert item['id'] == identity and type(identity) is str and identity
        assert 'error' not in item and len(item['choices']) == 1
        choice = item['choices'][0]
        assert type(choice['index']) is int and choice['index'] == 0
        delta = choice['delta']
        if i == 0:
            assert delta == {'role': 'assistant'}
        for key in ('content', 'reasoning_content', 'reasoning'):
            value = delta.get(key)
            assert value is None or type(value) is str
            if value:
                assert not finish
                (contents if key == 'content' else reasonings).append((clock, value))
        if choice.get('finish_reason') is not None:
            assert i == len(events)-2 and delta == {} and not finish
            finish.append((choice['finish_reason'], clock))
        if item.get('usage') is not None:
            usage.append(item['usage'])
    assert len(finish) == len(usage) == 1 and finish[0][0] == 'length'
    assert len(contents) == 128 and not reasonings and len(events) == 131
    counts = usage[0]
    assert set(counts) == {'prompt_tokens', 'completion_tokens', 'total_tokens'}
    for value in counts.values():
        integer(value)
    assert counts['completion_tokens'] == 128
    assert counts['total_tokens'] == counts['prompt_tokens']+128
    first = contents[0][0]
    deadline = 10_000_000_000+counts['prompt_tokens']*1_000_000
    measurement = receipt['measurement']
    assert measurement['usage'] == counts
    assert measurement['first_content_ns'] == measurement['first_text_ns'] == measurement['ttft_ns'] == first
    assert measurement['first_reasoning_ns'] is None
    assert measurement['last_text_ns'] == contents[-1][0]
    assert measurement['text_events'] == 128 and measurement['event_count'] == len(events)
    assert measurement['content_sla'] == {'reported_prompt_tokens': dict(
        deadline_ns=deadline, content_margin_ns=deadline-first,
        content_received_in_time=True, request_passed=True)}
    assert deadline >= first and measurement['finish_reason'] == 'length'
    assert measurement['done'] is True and measurement['stream_terminal_complete'] is True
    assert measurement['requested_output_tokens'] == 128 and measurement['reported_output_is_128'] is True
    assert measurement['engine_prefill_tps'] is None and measurement['engine_decode_tps'] is None
    assert receipt['headers_received_ns'] <= arrivals[0]['elapsed_ns'] <= first
    assert events[-1][1] <= measurement['elapsed_ns'] < receipt['timeout_seconds']*1e9
    return dict(rawBytes=len(raw), retainedLines=len(lines), events=len(events),
                nonemptyContentEvents=len(contents), reasoningEvents=0,
                firstContentNS=first, usage=counts, reportedCountDeadlineNS=deadline,
                contentMarginNS=deadline-first, finishReason='length', doneDelimiterNS=events[-1][1],
                contentUTF8SHA256=sha(''.join(x[1] for x in contents).encode()),
                rawTerminalFramingReplayed=True, arrivalArithmeticReplayed=True,
                HTTPBodyEOFSourceBound=True, rawSocketOrClockIndependentlyAttested=False)


def attempt(number, prompt_name, expected_count, expected_first):
    path = HARNESS / ('physical-'+str(number))
    receipt = doc(path/'client/receipt.json')
    execution = doc(path/'execution.json')
    supervisor = doc(path/'supervisor.json')
    pins = doc(path/'input-pins.json')
    for name, expected in pins.items():
        assert sha(read(Path(name))) == expected
        snapshot = path/'source-snapshot'/Path(name).relative_to(ROOT)
        if snapshot.exists():
            assert sha(read(snapshot)) == expected
    request_raw = read(path/'client/request.json')
    request = decode(request_raw)
    prompt = read(CLIENT/'prompts'/prompt_name)
    assert sha(request_raw) == receipt['request_sha256']
    assert sha(prompt) == receipt['prompt_utf8_sha256']
    assert request == dict(model='Qwen3.5-9B', messages=[dict(role='user', content=prompt.decode())],
        stream=True, stream_options=dict(include_usage=True), max_tokens=128, temperature=0,
        top_p=1, top_k=0, repetition_penalty=1, presence_penalty=0, frequency_penalty=0,
        enable_thinking=False, reasoning_parser='qwen3')
    assert receipt['status'] == 'completed' and receipt['error'] is None
    assert receipt['capture_complete'] is True and receipt['http_status'] == 200
    for flag in ['server_token_count_independently_verified', 'model_answer_correctness_verified',
                 'native_retirement_verified', 'owner_release_verified', 'cancellation_qualification',
                 'engine_performance_measured', 'product_qualification']:
        assert receipt[flag] is False
    parsed = stream(path/'client', receipt)
    assert parsed['usage']['prompt_tokens'] == expected_count and parsed['firstContentNS'] == expected_first
    assert execution['completed'] is True and execution['requestCount'] == 1
    assert execution['clientExitCode'] == execution['supervisorExitCode'] == supervisor['exitCode'] == 0
    assert supervisor['forcedKill'] is False and supervisor['stopReason'] == 'requested-stop'
    assert supervisor['pid'] == execution['supervisorStarted']['pid'] == execution['discovery']['pid']
    assert execution['supervisorFinal'] == [dict(state='exited', **supervisor)]
    assert decode(read(path/'supervisor.stdout.tail.jsonl')) == execution['supervisorFinal'][0]
    assert not execution['guardErrors'] and not execution['postflightObservationErrors']
    assert execution['monitors'] == [dict(exitCode=0, errors=[])]*2
    assert execution['nativeProcessesAbsent'] is True and execution['journalsEmpty'] is True
    assert execution['pinsUnchanged'] is True and 'error' not in execution
    assert len(execution['postflight']) == 2
    for post in execution['postflight']:
        assert post == dict(active=[], journalBytes=0, journalSHA256=sha(b''))
    cleanup = execution['aliasCleanup']
    assert cleanup['exitCode'] == 0 and cleanup['restored'] is True and len(cleanup['final']) == 1
    lease = decode(read(path/'lease.stdout.tail.jsonl'))
    assert cleanup['final'] == [lease] and lease['restored'] is True
    assert 'error' not in lease and 'cleanupError' not in lease
    before, added, after = [lease[k] for k in ('before', 'afterAdd', 'afterRemove')]
    for row in [added, after]:
        assert re.findall(r'member: (\S+)', before['bridge0']) == re.findall(r'member: (\S+)', row['bridge0'])
        assert before['bridge0'].splitlines()[0] == row['bridge0'].splitlines()[0]
        assert re.findall(r'^\s*(?:gateway|interface):\s*(.*)$', before['managementRoute'], re.M) == re.findall(r'^\s*(?:gateway|interface):\s*(.*)$', row['managementRoute'], re.M)
    alias = lease['address']
    assert 'inet '+alias+' ' in added['en1'] and '::ffff:'+alias in added['gid']
    assert all('inet '+alias+' ' not in row['en1'] and '::ffff:'+alias not in row['gid'] for row in [before,after])
    assert not (path/'token.private').exists()
    for name in ['client.stderr','supervisor.stderr','resources-0.stderr','resources-1.stderr','lease.stderr']:
        assert read(path/name) == b''
    diagnostics = read(path/'provider.stderr').decode()
    read(path/'provider.stdout')
    stdout = decode(read(path/'client.stdout'))
    assert stdout['measurement'] == receipt['measurement'] and stdout['status'] == receipt['status']
    assert [x['id'] for x in doc(path/'catalog.json')['data']] == ['Qwen3.5-9B']
    return dict(attempt=number, replayPassed=True, stream=parsed,
                resources=[resources(path/('resources-%d.jsonl'%rank)) for rank in range(2)],
                enclosingCleanup=dict(providerExitCode=0, forcedKill=False,
                    remoteProcessScansEmpty=True, journalsEmpty=True, aliasRestorationReplayed=True,
                    directPerRankACKTranscriptRetained=False,
                    successfulCLIExitImpliesCleanupUnderReviewedSource=True,
                    shutdownCancellationDiagnosticPresent='CancellationError' in diagnostics,
                    shutdownAlreadyClosedDiagnosticPresent='Already closed' in diagnostics),
                limitations=['Server-reported token counts, no independent tokenization or numerical answer comparison.',
                    'Single request in a fresh installed session; short/medium smoke only, not sustained, representative, long-prompt, OpenRouter or release qualification.',
                    'External send-to-content timing; no engine throughput or cross-host clock alignment.',
                    'Retained resource samples and remote postflight observations; not continuous memory proof or independent hardware attestation.',
                    'HTTP EOF is established by the pinned client path and receipt; the raw file itself proves terminal SSE framing only.',
                    'No per-rank cleanup/ACK transcript in this HTTP capture; normal CLI exit is interpreted through the installed source contract and corroborating empty journals/process scans.'])


def main():
    manifest = doc(CLIENT/'manifest.json')
    assert sha((CLIENT/'manifest.json').read_bytes()) == '809b6e9685d3bd3bf4e5c0e1f909f7b787a56c149a6e4792b8acb914ea0e6d0c'
    for member in manifest['members']:
        raw = read(CLIENT/member['path'])
        assert len(raw) == member['bytes'] and sha(raw) == member['sha256']
    bundle_root = ROOT/'installed-distributed-product-bundle-20260915'
    bundle = doc(bundle_root/'bundle.json')
    for member in bundle['files']:
        raw = read(bundle_root/member['path'])
        assert len(raw) == member['bytes'] and sha(raw) == member['sha256']
    expected = [{k: item[k] for k in ('path','sha256','bytes')} for item in bundle['files']]
    for folder, rank in [('installed-distributed-deployment-20260915',24), ('installed-distributed-deployment-attempt2-20260915',48)]:
        verification = doc(ROOT/folder/('darkbloom-%d.verification.json'%rank))
        assert verification['exitCode'] == 0 and verification['stderr'] == ''
        values = decode(verification['stdout'])
        assert values['verified'] == expected
        assert values['descriptorSHA256'] == sha((bundle_root/'capability.json').read_bytes())
    results = [attempt(2,'short.txt',42,1_339_245_042), attempt(3,'medium.txt',963,2_461_908_417)]
    report = dict(schema='installed_http_independent_retained_record_audit_v1', mode='retrospective CPU/read-only',
        producerCodeImported=False, networkOrNativeExecuted=False, modelPayloadRead=False,
        frozenClientMembersVerified=len(manifest['members']), localBundleMembersRehashed=len(expected),
        remoteDeploymentRecordListsMatched=True, remoteInstallationIndependentlyReobserved=False,
        attempts=results, inputs=INPUTS)
    with (HERE/'replay-results.json').open('x') as file:
        json.dump(report,file,indent=2,sort_keys=True); file.write('\n')
    print(json.dumps(dict(passed=True, attempts=results),indent=2))


if __name__ == '__main__':
    main()
