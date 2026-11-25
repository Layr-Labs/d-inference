"""Admit one passed owner launch and bind both independently retained sidecars."""
from pathlib import Path, PurePosixPath
import re
from sidecar_files import MAX_SIDECAR, bounded_bytes, file_record, parse, pin, require, sha

from owner_sidecar_configuration import require_configuration

MAX_STDOUT = 8 * 1024 * 1024
OWNER_RUNTIME = {
    'launch_remote_long_solo.py': '04ea975234e7abd3b71b35ca9f9cca74f8d65a63110afe2b5638301446475f83',
    'long_reference_configuration.py': '545f1cad8e1821598e8a3872274cf1e3b1576b5a76f4cda3061e1c42e37865bb',
}


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
    require(receipt['kind'] == 'remote_qwen_long_prefill_solo_owner_launcher'
            and type(receipt['schema_version']) is int and receipt['schema_version'] == 1,
            'Not the admitted owner launcher namespace')
    for key in ('passed', 'phase_timing_requested', 'owner_timing_requested', 'full_solo_forward_requested',
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
    require_configuration(configuration, receipt)
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
        if name in OWNER_RUNTIME:
            require(sha(data) == OWNER_RUNTIME[name], 'Frozen owner launcher source differs')
    require(set(OWNER_RUNTIME) <= names, 'Owner launcher runtime source missing')
    common_identity = dict(requestFingerprint=fingerprint, profile=first['profile'], role='solo')
    sidecars = [dict(name='phase', host=host, remote_path=remote_path, expected_identity=common_identity),
                dict(name='owner', host=host, remote_path=remote_path.removesuffix('phase-trace.json') + 'owner-trace.json',
                     expected_identity=dict(common_identity, frameSequence=7, tokenOffset=3584,
                                            tokenCount=512, committedFrontier=4096))]
    return dict(sidecars=sidecars, run=str(run), launcher_receipt_sha256=sha(raw), host=host, remote_path=remote_path,
                expected_identity=dict(requestFingerprint=fingerprint, profile=first['profile'], role='solo'),
                launcher_ssh_client_pid=execution['local_ssh_client_pid'], native_files=retained,
                launcher_files=launcher, archive_manifests=source_pins,
                expected_native_sha256=pin(receipt['expected_native_sha256']))
