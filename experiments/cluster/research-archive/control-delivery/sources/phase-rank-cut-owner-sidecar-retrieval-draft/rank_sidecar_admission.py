"""Admit both completed rank owners before any sidecar SSH read."""
from pathlib import Path, PurePosixPath
import re
from rank_sidecar_archives import archives, rank_files
from rank_sidecar_evidence import FLOW, canonical, native_identity
from sidecar_files import bounded_bytes, parse, pin, require, sha
from rank_sidecar_selection import validate_receipt_selection


def locations(receipt):
    host, epoch, paths = receipt['execution_host'], receipt['epoch'], receipt['remote_paths']
    require(isinstance(host, str) and re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.-]{0,127}', host), 'Unsafe SSH host alias')
    require(isinstance(epoch, str) and re.fullmatch('[0-9a-f]{32}', epoch)
            and receipt['run_id'] == epoch, 'Invalid/mismatched owned epoch')
    directories = paths['rank_directories']
    require(type(directories) is list and len(directories) == 2, 'Two ordered owned directories required')
    for value in [paths[key] for key in ('root', 'run', 'bundle', 'model')] + directories:
        require(isinstance(value, str) and re.fullmatch(r'/(?:[A-Za-z0-9_.-]+/)*[A-Za-z0-9_.-]+', value)
                and str(PurePosixPath(value)) == value and '..' not in PurePosixPath(value).parts,
                'Unsafe owned remote path')
    require(paths['run'] == paths['root'] + '/' + epoch and paths['bundle'] == paths['run'] + '/bundle'
            and directories == [paths['run'] + '/rank-' + str(rank) for rank in (0, 1)],
            'Rank directory does not belong to exact epoch/rank')
    return host, [path + '/phase-trace.json' for path in directories]


def admit_run(run, expected_sha256):
    run = Path(run).resolve(strict=True)
    raw = bounded_bytes(run / 'receipt.json', 4 * 1024 * 1024)
    require(sha(raw) == pin(expected_sha256), 'Completed rank launcher receipt pin differs')
    receipt = parse(raw)
    expected = dict(kind='remote_qwen_long_prefill_rank_cut_owner_launcher', schema_version=1,
                    native_rank_count=2, transport='loopback-test', backend='ring', flow=FLOW, envelope_version=4,
                    stage_logits_dtype='bfloat16')
    require(type(receipt) is dict and all(type(receipt.get(key)) is type(value) and receipt[key] == value
            for key, value in expected.items()), 'Wrong rank-owner launcher namespace/geometry')
    validate_receipt_selection(receipt)
    require(receipt['stage_prefill_policy'] in ('serial_v1', 'prompt_lookahead_one_v1'), 'Unsupported recorded policy')
    for key in ('passed', 'phase_timing_requested', 'owner_timing_requested', 'stage_model_forward_requested', 'timing_requested',
                'timing_diagnostic_only', 'native_execution_attempted',
                'source_bundle_raw_inputs_and_remote_model_unchanged_after_run'):
        require(receipt.get(key) is True, 'Launcher did not pass required gate: ' + key)
    require(receipt.get('primary_failure') is None and receipt.get('cleanup_errors') == []
            and receipt.get('post_run_errors') == [], 'Launcher retains a failure')
    cohort = receipt['cohort']
    require(cohort.get('passed') is True and cohort.get('cancellation_reason') is None
            and cohort.get('error') is None and cohort.get('cleanup_errors') == [], 'Rank cohort did not pass')
    for field, expected_value in [('exit_codes', [0, 0]), ('local_ssh_clients_reaped', [True, True])]:
        require(type(cohort.get(field)) is list and len(cohort[field]) == 2
                and all(type(value) is type(expected_value[index]) and value == expected_value[index]
                        for index, value in enumerate(cohort[field])), 'Both successful clients must be reaped')
    counts = cohort['validation']['records_per_rank']
    require(type(counts) is list and len(counts) == 2 and all(type(value) is int and value == 2 for value in counts)
            and cohort['validation']['shared_agreement_matches'] is True, 'Both complete matching rank reports required')
    pids = cohort['local_ssh_client_pids']
    require(type(pids) is list and len(pids) == 2 and all(type(pid) is int and pid > 0 for pid in pids)
            and pids[0] != pids[1], 'Two distinct recorded local SSH PIDs required')
    require(type(receipt['rank_configuration_sha256']) is list and len(receipt['rank_configuration_sha256']) == 2,
            'Two ordered configuration pins required')
    host, remote_paths = locations(receipt)
    manifests = archives(run, receipt)
    raw_files, retained = rank_files(run, receipt)
    identities = [native_identity(raw_files, receipt, rank) for rank in (0, 1)]
    require(canonical(identities[0]['agreement']) == canonical(identities[1]['agreement'])
            and identities[0]['agreement_fingerprint'] == identities[1]['agreement_fingerprint']
            and canonical(identities[0]['request']) == canonical(identities[1]['request'])
            and raw_files['rank-0/prompt.json'] == raw_files['rank-1/prompt.json'],
            'Peers disagree on the exact admitted request/agreement')
    ranks = [dict(rank=rank, host=host, remote_path=remote_paths[rank],
                  expected_identity=identities[rank]['expected_identity'], launcher_ssh_client_pid=pids[rank])
             for rank in (0, 1)]
    sidecars = []
    for rank in ranks:
        sidecars.append(dict(rank, name='phase'))
        sidecars.append(dict(rank, name='owner',
            remote_path=rank['remote_path'].removesuffix('phase-trace.json') + 'owner-trace.json',
            expected_identity=dict(rank['expected_identity'], frameSequence=7, tokenOffset=3584,
                                   tokenCount=512, committedFrontier=4096)))
    return dict(sidecars=sidecars, run=str(run), launcher_receipt_sha256=sha(raw), host=host, epoch=receipt['epoch'],
        stage_prefill_policy=receipt['stage_prefill_policy'], selected_layer_plan=receipt['selected_layer_plan'],
        ranks=ranks, rank_files=retained,
        archive_manifests=manifests, launcher_files=receipt['launcher_files'],
        agreement_fingerprint=identities[0]['agreement_fingerprint'],
        recorded_request_json_sha256=sha(canonical(identities[0]['request'])),
        expected_native_sha256=pin(receipt['expected_native_sha256']))
