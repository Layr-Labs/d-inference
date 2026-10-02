"""Admit a completed phase launch and correlate one opaque diagnostic sidecar."""
from pathlib import Path, PurePosixPath
import re
from sidecar_files import MAX_SIDECAR, bounded_bytes, file_record, parse, pin, require, sha

MAX_STDOUT = 8 * 1024 * 1024


def remote_location(receipt):
    host, run_id, paths = receipt['execution_host'], receipt['run_id'], receipt['remote_paths']
    require(isinstance(host, str) and re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.-]{0,127}', host),
            'Unsafe SSH host alias')
    require(isinstance(run_id, str) and re.fullmatch('[0-9a-f]{32}', run_id), 'Invalid owned run UUID')
    for key in ('root', 'run', 'native'):
        value = paths[key]
        require(isinstance(value, str) and re.fullmatch(r'/(?:[A-Za-z0-9_.-]+/)*[A-Za-z0-9_.-]+', value)
                and str(PurePosixPath(value)) == value and '..' not in PurePosixPath(value).parts,
                'Unsafe owned remote path')
    require(paths['run'] == paths['root'] + '/' + run_id
            and paths['native'] == paths['run'] + '/native', 'Owned native path differs from run UUID')
    return host, paths['native'] + '/phase-trace.json'


def admit_run(run, expected_sha256):
    run = Path(run).resolve(strict=True)
    raw = bounded_bytes(run / 'receipt.json', 4 * 1024 * 1024)
    require(sha(raw) == pin(expected_sha256), 'Completed launcher receipt pin differs')
    receipt = parse(raw)
    require(receipt['kind'] == 'remote_qwen_long_prefill_solo_phase_launcher'
            and type(receipt['schema_version']) is int and receipt['schema_version'] == 1,
            'Not the admitted phase launcher namespace')
    for key in ('passed', 'phase_timing_requested', 'full_solo_forward_requested',
                'timing_requested', 'timing_diagnostic_only', 'native_execution_attempted',
                'source_bundle_raw_inputs_and_remote_model_unchanged_after_run'):
        require(receipt.get(key) is True, 'Launcher did not pass required gate: ' + key)
    require(receipt.get('primary_failure') is None and receipt.get('cleanup_errors') == []
            and receipt.get('post_run_errors') == [], 'Launcher retains a failure')
    execution = receipt['execution']
    require(execution.get('passed') is True and execution.get('local_ssh_client_reaped') is True
            and type(execution.get('exit_code')) is int and execution['exit_code'] == 0
            and execution.get('cancellation_reason') is None and execution.get('error') is None
            and execution.get('cleanup_errors') == [] and type(execution.get('validated_outer_records')) is int
            and execution['validated_outer_records'] == 2,
            'Successful launcher SSH completion was not established')
    require(type(execution.get('local_ssh_client_pid')) is int and execution['local_ssh_client_pid'] > 0,
            'Missing original launcher SSH PID')
    host, remote_path = remote_location(receipt)
    native, retained = {}, []
    limits = {'native/rank.json': 256 * 1024, 'native/stdout.jsonl': MAX_STDOUT, 'native/stderr.log': 64 * 1024}
    entries = receipt['native_files']
    require(type(entries) is list and len(entries) == 3, 'Expected three pinned native archive files')
    for entry in entries:
        name = entry['path']
        require(name in limits and name not in native and entry.get('hash_omitted_because_oversized') is False,
                'Invalid native archive entry')
        data = bounded_bytes(run / name, limits[name])
        require(type(entry['size_bytes']) is int and len(data) == entry['size_bytes']
                and sha(data) == pin(entry['sha256']), 'Pinned native file differs: ' + name)
        native[name] = data
        retained.append(file_record(name, data))
    require(native['native/stderr.log'] == b'', 'Solo native stderr was not empty')
    require(sha(native['native/rank.json']) == pin(receipt['rank_configuration_sha256']), 'Rank configuration pin differs')
    configuration = parse(native['native/rank.json'])
    arguments = configuration['arguments']
    for flag, value in [('--mode', 'qwen-long-prefill-solo-check'),
                        ('--prefill-phase-trace-file', '@rank/phase-trace.json')]:
        require(type(arguments) is list and arguments.count(flag) == 1
                and arguments.index(flag) + 1 < len(arguments)
                and arguments[arguments.index(flag) + 1] == value, 'Phase native argument differs')
    require(native['native/stdout.jsonl'].endswith(b'\n'), 'Incomplete native stdout')
    rows = native['native/stdout.jsonl'].splitlines()
    require(len(rows) == 2 and all(rows), 'Expected exactly two completed native records')
    first, final = map(parse, rows)
    require(first['kind'] == 'qwen_long_prefill_solo_ready'
            and final['kind'] == 'qwen_long_prefill_solo_report'
            and type(first['schemaVersion']) is int and type(final['schemaVersion']) is int
            and first['schemaVersion'] == final['schemaVersion'] == 1
            and final.get('completed') is True and final.get('allRequestStateRetired') is True
            and final.get('modelReleased') is True, 'Native owner did not report successful completion')
    fingerprint = pin(first['recordedRequestFingerprint'])
    require(final['execution']['request']['fingerprint'] == fingerprint
            and first['profile'] == final['profile'] == 'long_prefill_8k_v1',
            'Native ready and completed history/profile differ')
    source_pins = {}
    for name, field in [('source-manifest.json', 'source_manifest_sha256'),
                        ('bundle/bundle.json', 'bundle_manifest_sha256')]:
        data = bounded_bytes(run / name, 4 * 1024 * 1024)
        require(sha(data) == pin(receipt[field]), 'Archive manifest pin differs: ' + name)
        source_pins[name] = file_record(name, data)
    launcher = receipt['launcher_files']
    require(type(launcher) is list and 1 <= len(launcher) <= 64, 'Launcher archive count')
    names, total = set(), 0
    for entry in launcher:
        name = entry['path']
        require(isinstance(name, str) and re.fullmatch(r'[A-Za-z0-9_]+\.py', name) and name not in names,
                'Unsafe or repeated launcher archive path')
        names.add(name)
        data = bounded_bytes(run / 'launcher' / name, 1024 * 1024)
        total += len(data)
        require(total <= 8 * 1024 * 1024 and type(entry['size_bytes']) is int and len(data) == entry['size_bytes']
                and sha(data) == pin(entry['sha256']), 'Launcher archive differs')
    require({'launch_remote_long_solo.py', 'long_reference_configuration.py'} <= names,
            'Phase launcher runtime source missing')
    return dict(run=str(run), launcher_receipt_sha256=sha(raw), host=host, remote_path=remote_path,
                expected_identity=dict(requestFingerprint=fingerprint, profile=first['profile'], role='solo'),
                launcher_ssh_client_pid=execution['local_ssh_client_pid'], native_files=retained,
                launcher_files=launcher, archive_manifests=source_pins,
                expected_native_sha256=pin(receipt['expected_native_sha256']))


def decode_response(data, context):
    require(type(data) is bytes and len(data) <= MAX_SIDECAR + 4097 and b'\n' in data,
            'Bounded metadata/raw sidecar framing missing')
    header, raw = data.split(b'\n', 1)
    require(len(header) <= 4096 and 0 < len(raw) <= MAX_SIDECAR, 'Sidecar response bounds')
    metadata = parse(header)
    keys = {'kind', 'schema_version', 'path', 'sha256', 'size_bytes', 'mode', 'uid', 'gid',
            'device', 'inode', 'link_count', 'mtime_ns', 'ctime_ns', 'stable_descriptor_read',
            'followed_symlinks', 'remote_file_modified'}
    require(type(metadata) is dict and set(metadata) == keys
            and metadata['kind'] == 'qwen_prefill_phase_sidecar_read'
            and type(metadata['schema_version']) is int and metadata['schema_version'] == 1,
            'Unexpected remote reader schema')
    require(metadata['path'] == context['remote_path'] and metadata['sha256'] == sha(raw)
            and type(metadata['size_bytes']) is int and metadata['size_bytes'] == len(raw)
            and type(metadata['mode']) is int and metadata['mode'] == 0o600
            and type(metadata['link_count']) is int and metadata['link_count'] == 1,
            'Remote sidecar identity, mode, or size differs')
    require(all(type(metadata[key]) is int and metadata[key] >= 0
                for key in ('uid', 'gid', 'device', 'inode', 'mtime_ns', 'ctime_ns'))
            and metadata['stable_descriptor_read'] is True and metadata['followed_symlinks'] is False
            and metadata['remote_file_modified'] is False, 'Invalid remote descriptor observations')
    trace = parse(raw)
    require(type(trace) is dict and trace.get('kind') == 'qwen_prefill_local_phase_trace'
            and type(trace.get('schemaVersion')) is int and trace['schemaVersion'] == 1
            and trace.get('identity') == context['expected_identity']
            and trace.get('clockSource') == 'DispatchTime.uptimeNanoseconds', 'Sidecar request/profile/clock mismatch')
    for key, expected in [('diagnosticOnly', True), ('includesRecorderOverhead', True),
                          ('crossProcessClockAlignmentAsserted', False), ('gpuOverlapAsserted', False),
                          ('modelReleaseAsserted', False), ('recorderIndependentlyVerifiesRequestRetirement', False)]:
        require(trace.get(key) is expected, 'Sidecar qualification flag differs: ' + key)
    require(type(trace.get('maximumEvents')) is int and 1 <= trace['maximumEvents'] <= 1024
            and type(trace.get('events')) is list and 1 <= len(trace['events']) <= trace['maximumEvents'],
            'Sidecar event collection bounds')
    return raw, metadata, dict(identity=trace['identity'], clock_source=trace['clockSource'],
                               event_count=len(trace['events']), event_sequence_semantics_audited=False)
