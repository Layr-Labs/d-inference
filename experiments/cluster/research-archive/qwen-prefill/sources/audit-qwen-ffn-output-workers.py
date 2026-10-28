"""CPU-only audit of saved wider-output worker/failure records; never starts native code."""
import copy
import hashlib
import json
import math
from pathlib import Path
import struct
import sys

sys.dont_write_bytecode = True
ROOT = Path('/Users/developer/DarkbloomDev/cluster-research')
WORK = ROOT / 'runs/qwen-ffn-output-workers-20260913'
FAIL = ROOT / 'runs/qwen-ffn-output-failures-20260913'
HASHES = {}


def sha(path):
    path = Path(path)
    if str(path) not in HASHES:
        digest = hashlib.sha256()
        with path.open('rb') as stream:
            for block in iter(lambda: stream.read(1024 * 1024), b''):
                digest.update(block)
        HASHES[str(path)] = digest.hexdigest()
    return HASHES[str(path)]


def closed(pairs):
    result = {}
    for key, value in pairs:
        assert key not in result, 'Duplicate JSON key: ' + key
        result[key] = value
    return result


def parse(raw):
    return json.loads(raw, object_pairs_hook=closed,
                      parse_constant=lambda token: (_ for _ in ()).throw(ValueError(token)))


def read(path):
    sha(path)
    return parse(Path(path).read_text())


def frames(path):
    sha(path)
    raw = Path(path).read_bytes()
    assert not raw or raw.endswith(b'\n'), 'Incomplete JSONL frame'
    return [parse(line) for line in raw.splitlines()]


def archive(base, driver):
    receipt = read(base / 'receipt.json')
    assert receipt['synthetic_only'] and not receipt['performance_qualification']
    assert sha(base / driver) == receipt['driver_sha256']
    assert sha(base / 'source-manifest.json') == receipt['source_manifest_sha256']
    entries = read(base / 'source-manifest.json')
    assert len({e['path'] for e in entries}) == len(entries)
    for entry in entries:
        path = base / 'source' / Path(entry['path']).relative_to('experiments/cluster')
        assert sha(path) == entry['sha256']
        if 'size_bytes' in entry:
            assert path.stat().st_size == entry['size_bytes']
    return receipt, len(entries)


workers, worker_source_count = archive(WORK, 'validate-qwen-ffn-output-workers.py')
failures, failure_source_count = archive(FAIL, 'validate-qwen-ffn-output-failures.py')
sys.path.insert(0, str(WORK / 'source'))
from runtime import persistent_protocol as protocol
from runtime.configuration import validate
from runtime.reports import reports, validate_report
assert protocol.VERSION == 5
for name in ('persistent_protocol.py', 'reports.py', 'partition_storage.py', 'configuration.py'):
    assert sha(WORK / 'source/runtime' / name) == sha(FAIL / 'source/runtime' / name)
BINARY = workers['binary_sha256']
assert failures['binary_sha256'] == BINARY


def bundle(base, fingerprint):
    assert sha(base / 'bundle.json') == fingerprint
    manifest = read(base / 'bundle.json')
    assert manifest['schema_version'] == 1
    assert len({e['path'] for e in manifest['files']}) == len(manifest['files'])
    for entry in manifest['files']:
        path = base / entry['path']
        assert path.resolve().is_relative_to(base.resolve())
        assert path.stat().st_size == entry['size_bytes'] and sha(path) == entry['sha256']
    assert sha(base / 'cluster-inference') == BINARY


def argv_value(arguments, flag):
    assert arguments.count(flag) == 1
    return arguments[arguments.index(flag) + 1]


def f32bytes(rows):
    result = bytearray()
    for row in rows:
        assert len(row) == 512
        for value in row:
            assert type(value) in (int, float) and math.isfinite(value)
            result += struct.pack('<f', value)
    return bytes(result)


def same_logits(a, b):
    assert a == b
    assert f32bytes(a) == f32bytes(b)


def ready_session(base, session, expected_ready):
    spec = validate(copy.deepcopy(session['spec']))
    assert spec == session['spec']
    assert session['ready'] == expected_ready
    bundle(base / 'bundle', session['bundle_manifest_sha256'])
    result = []
    for rank, descriptor in enumerate(session['ranks']):
        assert descriptor['rank'] == rank and descriptor['host'] is None
        path = base / f'rank-{rank}'
        assert Path(descriptor['local']) == path
        config = read(path / 'rank.json')
        assert config['persistent'] and config['bundle_sha256'] == session['bundle_manifest_sha256']
        args = config['arguments']
        for flag, expected in [('--epoch', session['epoch']), ('--execution-path', 'cbv2-contiguous'),
            ('--ffn-output-precision', 'float32'), ('--attention-output-precision', spec['workload']['attention_output_precision']),
            ('--mode', 'worker' if len(session['ranks']) == 1 else 'worker-tp')]:
            assert argv_value(args, flag) == expected
        for forbidden in ('--logits-file', '--tokens-file', '--teacher-tokens-file', '--prompt-tokens',
                          '--chunk-size', '--decode-tokens', '--warmups', '--repeats'):
            assert forbidden not in args
        raw = frames(path / 'stdout.jsonl')
        assert raw[0] == expected_ready[rank]
        protocol.ready(raw[0], session['epoch'], rank, spec)
        sha(path / 'stderr.log')
        result.append(raw)
    assert all(r['identity'] == expected_ready[0]['identity'] for r in expected_ready)
    return spec, result


prompt_a = [3 + (i * 17 + 7) % 509 for i in range(65)]
prompt_b = [3 + (i * 13 + 31) % 509 for i in range(37)]
REQUESTS = [('A-first', prompt_a, 32, 6, None), ('B', prompt_b, 16, 6, [12,25,38,51,64]),
            ('A-last', prompt_a, 32, 6, None), ('single', [3], 1, 1, None)]
counts = dict(cohorts=0, logical_requests=0, rank_completed_events=0, native_workers=0,
              raw_worker_frames=0, callback_tokens=0, rank_token_frames=0, logit_values=0,
              fresh_oneshot_runs=0, fresh_oneshot_rank_reports=0, schema8_mutations_rejected=0)
cohort_results = []
assert [c['name'] for c in workers['cohorts']] == [f'{p}-bfloat16-{part}'
    for p in ('tiny','qwen27-heads') for part in ('solo','ffn','full')]
for case in workers['cohorts']:
    name = case['name']; base = WORK / name
    session = read(base / 'session.json')
    assert session['state'] == case['final_state'] == 'closed'
    spec, raws = ready_session(base, session, case['ready'])
    assert spec == validate(read(WORK / (name + '.spec.json')))
    assert spec['workload']['prompt_ids'] == prompt_a and spec['workload']['seed'] == 7
    assert spec['workload']['synthetic_dtype'] == 'bfloat16'
    assert len(case['requests']) == len(session['requests']) == 4
    cursors = [1] * len(raws)
    for sequence, (request_id, prompt, chunk, output, teacher) in enumerate(REQUESTS, 1):
        command = protocol.request(session['epoch'], sequence, request_id, prompt, output,
                                   chunk, teacher, True, 30, case['ready'][0])
        summary = session['requests'][sequence - 1]
        assert summary == dict(sequence=sequence, requestID=request_id,
                               requestSHA256=protocol.hash_frame(command), status='completed')
        saved = case['requests'][sequence - 1]
        assert saved['request_id'] == request_id and len(saved['events']) == len(raws)
        for rank, raw in enumerate(raws):
            cursor = cursors[rank]; ready = case['ready'][rank]
            protocol.frame(raw[cursor], 'accepted', session['epoch'], rank, sequence,
                           command, ready['modelLoadID'])
            tokens = []
            for step in range(output):
                event = raw[cursor + step + 1]
                protocol.frame(event, 'token', session['epoch'], rank, sequence, command)
                assert event['step'] == step
                tokens.append(event['token'])
            completed = raw[cursor + output + 1]
            protocol.completed(completed, command, ready, rank, tokens)
            assert completed == saved['events'][rank]
            assert saved['tokens'] == [list(x) for x in enumerate(tokens)]
            same_logits(completed['logits'], saved['events'][0]['logits'])
            result = completed['result']
            assert result['decodeInputTokens'] == (teacher if teacher is not None else tokens[:-1])
            assert result['decodeForwardCount'] == output - 1
            if output == 1:
                assert result['decodeSeconds'] == 0 and result['decodeStepSeconds'] == []
                assert 'decodeTokensPerSecond' not in result
            cursors[rank] = cursor + output + 2
            counts['rank_completed_events'] += 1
            counts['rank_token_frames'] += output
            counts['logit_values'] += len(completed['logits']) * 512
        counts['logical_requests'] += 1
        counts['callback_tokens'] += len(saved['tokens'])
    for rank, raw in enumerate(raws):
        assert len(raw) == cursors[rank] + 1
        protocol.frame(raw[-1], 'stopped', session['epoch'], rank, 5)
        counts['raw_worker_frames'] += len(raw)
    first = case['requests'][0]['events']; last = case['requests'][2]['events']
    for a, b in zip(first, last, strict=True):
        same_logits(a['logits'], b['logits'])
        for key in ('generatedTokens', 'decodeInputTokens', 'localArgmaxTokens'):
            assert a['result'][key] == b['result'][key]
    assert case['ABA_exact'] and case['oneshot_exact']
    oneshot = WORK / (name + '-oneshot'); run = read(oneshot / 'run.json')
    assert run['spec'] == spec and run['exit_codes'] == [0] * len(raws)
    assert run['verified_execution'] and not run['hardware_throughput_candidate']
    assert run['cancellation_reason'] is None
    bundle(oneshot / 'bundle', run['bundle_manifest_sha256'])
    validated = reports(run['ranks'], run['spec'])
    assert validated == run['reports']
    for rank, report in enumerate(validated):
        sha(oneshot / f'rank-{rank}/stdout.jsonl')
        sha(oneshot / f'rank-{rank}/stderr.log')
        assert report['schemaVersion'] == 9
        for key in ('model', 'modelFamily', 'configurationSHA256', 'partition', 'partitionPlanSHA256',
                    'attentionOutputPrecision', 'ffnOutputPrecision', 'ffnBranchPrecision', 'executionPath',
                    'syntheticDType', 'syntheticProfile', 'embeddingActivationDType', 'ffnScaleDTypes'):
            assert report.get(key, 'none') == case['ready'][rank]['identity'][key]
        assert report['parameterLayoutSHA256'] == case['ready'][rank]['parameterLayoutSHA256']
        same_logits(read(oneshot / f'rank-{rank}/logits.json'), first[rank]['logits'])
        for key in ('generatedTokens','decodeInputTokens','localArgmaxTokens'):
            assert report['runs'][0][key] == first[rank]['result'][key]
        obsolete = copy.deepcopy(report); obsolete['schemaVersion'] = 8
        try:
            validate_report(obsolete, spec, rank)
        except ValueError:
            counts['schema8_mutations_rejected'] += 1
        else:
            raise AssertionError('Schema8 report was accepted')
    counts['cohorts'] += 1; counts['native_workers'] += len(raws)
    counts['fresh_oneshot_runs'] += 1; counts['fresh_oneshot_rank_reports'] += len(validated)
    cohort_results.append(dict(name=name, workers=len(raws), requests=4,
        ABA_exact=True, fresh_oneshot_exact=True, all_peers_exact=True,
        one_token_decode_forwards=0, stopped_sequence=5))

# Failure source/bundle binding and cancellation protocol streams.
assert failures['status'] == 'passed' and failures['source_and_bundle_unchanged']
assert protocol.hash_frame(failures['bundle_files']) == failures['bundle_files_sha256']
for entry in failures['bundle_files']:
    path = Path(failures['bundle']) / entry['path']
    assert sha(path) == entry['sha256'] and path.stat().st_size == entry['size_bytes']
cancel_results = []
for case in failures['cancellation']:
    base = FAIL / ('cancel-' + case['partition']); session = read(base / 'session.json')
    assert sha(base / 'session.json') == case['session_sha256']
    assert session['epoch'] == case['epoch'] and session['state'] == 'failed'
    spec, raws = ready_session(base, session, case['ready'])
    assert spec['workload']['synthetic_dtype'] == 'float32'
    assert case['worker_pids'] == [r['pid'] for r in case['ready']]
    assert len(case['supervisor_pids']) == len(raws)
    assert len(set(case['worker_pids'] + case['supervisor_pids'])) == 2 * len(raws)
    assert case['all_native_workers_and_supervisors_reaped'] and case['epoch_reuse_rejected']
    assert 0 < case['cancellation_to_reaped_seconds'] < case['total_seconds']
    command = protocol.request(case['epoch'], 1, 'cancel-cbv2',
        [3 + (i * 17 + 7) % 253 for i in range(65)], 4096, 32, None, False, 15, case['ready'][0])
    assert len(session['requests']) == 1
    request = session['requests'][0]
    assert request['status'] == 'failed' and request['requestSHA256'] == protocol.hash_frame(command)
    assert request['failure'] == session['failure'] == 'Cancellation requested; epoch permanently retired'
    for rank, raw in enumerate(raws):
        assert [e['type'] for e in raw] == ['ready','accepted','token']
        protocol.frame(raw[1], 'accepted', case['epoch'], rank, 1, command, case['ready'][rank]['modelLoadID'])
        protocol.frame(raw[2], 'token', case['epoch'], rank, 1, command)
        assert case['delivered'] == [[raw[2]['step'], raw[2]['token']]] and raw[2]['step'] == 0
    cancel_results.append(dict(partition=case['partition'], native_workers=len(raws),
        supervisors=len(raws), recorded_deliveries=case['delivered'], terminal_state='failed',
        no_completion=True, native_reaping_observed_by_original_driver=True,
        reaping_milliseconds=case['cancellation_to_reaped_seconds']*1000))

mismatches = []
for key, name, expected_policies in [('native_command_mismatch','command-mismatch',['float32','float32']),
    ('native_ffn_output_precision_mismatch','identity-mismatch',['native','float32'])]:
    case = failures[key]; base = FAIL / name
    assert case['ffn_output_precisions'] == expected_policies
    arguments = []
    for rank, record in enumerate(case['ranks']):
        target = base / f'rank-{rank}'
        assert record['exit_code'] == 1 and record['rank'] == rank
        assert sha(target / 'stdout.jsonl') == record['stdout_sha256']
        assert sha(target / 'stderr.log') == record['stderr_sha256']
        assert (target / 'stderr.log').read_text().splitlines() == [
            'Using loopback-test transport for correctness only; timings are not cluster-performance evidence',
            'cluster-inference: Ranks disagree on the inference workload or model configuration']
        launch = read(target / 'launch.json'); args = launch['arguments']; arguments.append(args)
        assert launch['environment']['MLX_RANK'] == str(rank)
        assert argv_value(args, '--epoch') == case['epoch']
        assert argv_value(args, '--ffn-output-precision') == expected_policies[rank]
        raw = frames(target / 'stdout.jsonl')
        assert raw == ([] if name == 'identity-mismatch' else [case['ready'][rank]])
        assert record['no_accepted_or_token'] and record['no_ready'] == (name == 'identity-mismatch')
    if name == 'command-mismatch':
        assert arguments[0] == arguments[1]
        commands = read(base / 'requests.json')
        assert [protocol.hash_frame(c) for c in commands] == case['request_sha256']
        assert commands[0]['prompt'] == [3,7,11] and commands[1]['prompt'] == [3,8,11]
        assert {k:v for k,v in commands[0].items() if k!='prompt'} == {k:v for k,v in commands[1].items() if k!='prompt'}
        assert case['ready'][0]['identity'] == case['ready'][1]['identity']
        for rank, command in enumerate(commands):
            assert command == protocol.request(case['epoch'],1,'mismatched-prompt',command['prompt'],
                                                2,2,None,False,5,case['ready'][rank])
            spec = copy.deepcopy(read(FAIL / 'cancel-full/session.json')['spec']); spec['timeout_seconds'] = 15
            protocol.ready(case['ready'][rank], case['epoch'], rank, spec)
    else:
        a,b=copy.deepcopy(arguments)
        a[a.index('--ffn-output-precision')+1] = 'float32'
        assert a == b and case['ready'] == [] and case['request_sha256'] == []
    mismatches.append(dict(case=name, both_exit_codes=[1,1],
                          rejected_before='ready' if name=='identity-mismatch' else 'accepted',
                          no_tokens_or_completed=True))

# Four raw CLI logs, plus the separate six-case summary-only receipt.
for case in failures['unsupported_cli']:
    target = FAIL / ('unsupported-' + case['profile'] + '-' + case['execution_path']) / 'rank-0'
    launch = read(target / 'launch.json')
    assert argv_value(launch['arguments'],'--synthetic-profile') == case['profile']
    assert argv_value(launch['arguments'],'--execution-path') == case['execution_path']
    assert case['exit_code'] == 1 and case['no_ready_or_report'] and case['rejected_at_cli_validation']
    assert frames(target/'stdout.jsonl') == [] and sha(target/'stderr.log') == case['stderr_sha256']
    expected = ('Execution path must be ordinary or cbv2-contiguous' if case['execution_path']=='cbv2-paged'
                else 'cbv2-contiguous requires dense Qwen baseline or cooperative execution')
    assert (target/'stderr.log').read_text().strip() == 'cluster-inference: '+expected
cli = read(ROOT / 'qwen-ffn-output-cli-rejections-20260913.json')
assert cli['binary_sha256'] == BINARY and len(cli['cases']) == 6
native_source = FAIL / 'source/inference/Sources/ClusterInference'
options = (native_source/'Options.swift').read_text(); main = (native_source/'Main.swift').read_text()
for case in cli['cases']:
    assert case['exit_code'] == 1 and case['stdout_empty']
    assert case['error'].removeprefix('cluster-inference: ') in options
assert main.index('let options = try Options(') < main.index('_ = MLXArray(0)')
assert 'let schemaVersion = 9' in (native_source/'Report.swift').read_text()
assert failures['report_schema_version'] == 8 and failures['worker_protocol_version'] == 5
erratum = dict(schema_version=1, affected_receipt=str(FAIL/'receipt.json'),
    affected_receipt_sha256=sha(FAIL/'receipt.json'),
    affected_driver_sha256=sha(FAIL/'validate-qwen-ffn-output-failures.py'),
    field='report_schema_version', recorded=8, expected=9,
    classification='Stale summary annotation; original evidence preserved',
    basis=dict(binary_sha256=BINARY, archived_swift_report_source_sha256=sha(native_source/'Report.swift'),
               archived_python_report_validator_sha256=sha(FAIL/'source/runtime/reports.py'),
               actual_fresh_reports_schema=9, actual_fresh_report_count=10,
               worker_protocol=5, obsolete_schema8_mutations_rejected=10),
    actual_schema8_reports_observed_or_accepted=0,
    note='Failure cases emit worker protocol5 frames or no stdout, not benchmark reports. No native rerun performed.')

assert counts == dict(cohorts=6,logical_requests=24,rank_completed_events=40,native_workers=10,
    raw_worker_frames=290,callback_tokens=114,rank_token_frames=190,logit_values=97280,
    fresh_oneshot_runs=6,fresh_oneshot_rank_reports=10,schema8_mutations_rejected=10), counts
summary = dict(schema_version=1, status='passed_with_metadata_erratum', cpu_only=True,
    binary_sha256=BINARY, audit_script_sha256=sha(Path(__file__)),
    source_counts=dict(worker_archive=worker_source_count,failure_archive=failure_source_count),
    worker_counts=counts, cohorts=cohort_results, cancellation=cancel_results,
    native_mismatches=mismatches, unsupported_cli_raw_cases=len(failures['unsupported_cli']),
    additional_cli_summary_cases=len(cli['cases']),
    limitations=[
        'Synthetic local solo/loopback correctness only; no RDMA, throughput, real-artifact or model-quality qualification.',
        'Exactness means saved numerical JSON equality and independently reconstructed Float32 bytes; request/runtime protocol was revalidated from archived Python sources.',
        'A/B/A checks fresh per-request state on a reused load; fresh one-shot controls cover A only, not B or the one-token workload.',
        'Model-load count and identity are native self-reports; this audit confirms stable IDs and one ready per raw process stream.',
        'Historical cancellation reaping and reuse rejection are contemporaneous assertions of the hash-bound driver, not independently re-observed process state. Recorded streams/manifests independently show one token and permanent request failure.',
        'Six additional CLI rejections have only a summary receipt and binary fingerprint, not raw stream files; archived pre-load Options guards support their stated reason.',
        'Source archives and binary/resource fingerprints are integrity checked, not reproducible-build attestations.'
    ], metadata_erratum=erratum, evidence_sha256=dict(sorted(HASHES.items())))
output = WORK / 'independent-worker-failure-cpu-audit.json'
output.write_text(json.dumps(summary,indent=2,allow_nan=False)+'\n')
(FAIL/'report-schema-erratum.json').write_text(json.dumps(erratum,indent=2)+'\n')
print(json.dumps(dict(status=summary['status'], counts=counts, cancellation=cancel_results,
    evidence_files=len(HASHES), audit_path=str(output),audit_sha256=sha(output)),indent=2))
