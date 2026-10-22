"""Explicit current-workload identity; expected hashes always come from caller."""
from pathlib import PurePosixPath
import re
from long_reference_provenance_common import require

ENVIRONMENT = {'DARKBLOOM_BF16_WEIGHTS': '1', 'DARKBLOOM_CBV2_ATTN_QUERY_BLOCK': '128', 'MLX_ENABLE_TF32': '1'}


def validate_layout(receipt):
    require(type(receipt['run_id']) is str and re.fullmatch('[0-9a-f]{32}', receipt['run_id']), 'Invalid owned run ID')
    require(type(receipt['execution_host']) is str
            and re.fullmatch('[A-Za-z0-9][A-Za-z0-9_.-]{0,127}', receipt['execution_host']), 'Invalid SSH alias')
    remote = receipt['remote_paths']
    require(set(remote) == {'root', 'run', 'native', 'controls', 'bundle', 'model'}, 'Unexpected remote layout')
    for value in remote.values():
        require(type(value) is str and re.fullmatch(r'/(?:[A-Za-z0-9_.-]+/)*[A-Za-z0-9_.-]+', value)
                and str(PurePosixPath(value)) == value and '..' not in PurePosixPath(value).parts, 'Unsafe remote path')
    require(remote['run'] == remote['root'] + '/' + receipt['run_id']
            and remote['native'] == remote['run'] + '/native'
            and remote['controls'] == remote['run'] + '/controls'
            and remote['bundle'] == remote['native'] + '/bundle', 'Owned paths differ')
    root, model = PurePosixPath(remote['root']), PurePosixPath(remote['model'])
    require(root != model and root not in model.parents and model not in root.parents, 'Run overlaps model')
    return remote


def validate_completion(receipt, pins):
    require(receipt['kind'] == 'remote_qwen_long_prefill_pair_launcher'
            and type(receipt['schema_version']) is int and receipt['schema_version'] == 1, 'Wrong launcher namespace')
    for key in ('passed', 'native_execution_attempted', 'full_reference_forward_requested', 'stage_model_forward_requested',
                'source_bundle_raw_inputs_and_remote_model_unchanged_after_run', 'remote_pid_observations_are_not_reaping_proof'):
        require(receipt[key] is True, 'Missing completion flag: ' + key)
    for key in ('physical_two_machine_execution', 'interprocess_model_transport', 'throughput_qualification',
                'independent_reference_oracle_run', 'local_model_payload_verified',
                'timing_requested'):
        require(receipt[key] is False, 'Unexpected execution scope: ' + key)
    require(receipt['expected_native_sha256'] == pins.native
            and receipt['artifact_aggregate_sha256'] == pins.artifact
            and receipt['configuration_sha256'] == pins.configuration, 'Caller native/model pins differ')
    require(type(receipt['native_process_count']) is int and receipt['native_process_count'] == 1
            and type(receipt['native_timeout_seconds']) is int and receipt['native_timeout_seconds'] == 300
            and type(receipt['parent_timeout_seconds']) is int and 1 <= receipt['parent_timeout_seconds'] <= 330
            and receipt['primary_failure'] is None and receipt['cleanup_errors'] == []
            and receipt['post_run_errors'] == [], 'Launcher failure or deadline differs')
    execution = receipt['execution']
    require(execution['passed'] is True and type(execution['exit_code']) is int and execution['exit_code'] == 0
            and execution['local_ssh_client_reaped'] is True
            and execution['remote_process_reaping_independently_verified'] is False
            and execution['independent_comparison_oracle_run'] is False
            and type(execution['validated_outer_records']) is int and execution['validated_outer_records'] == 2
            and execution['error'] is None and execution['cancellation_reason'] is None
            and execution['cleanup_errors'] == [], 'Supervisor completion differs')
    require(type(execution['local_ssh_client_pid']) is int and execution['local_ssh_client_pid'] > 0, 'Invalid local SSH PID')
    validate_layout(receipt)
    return execution


def expected_rank(receipt, pins):
    remote = receipt['remote_paths']
    return dict(bundle=remote['bundle'], bundle_sha256=receipt['bundle_manifest_sha256'], rank=0,
        persistent=False, model_directory=remote['model'], artifact_aggregate_sha256=pins.artifact,
        timeout_seconds=300, environment=dict(ENVIRONMENT), environment_files={}, input_files={},
        arguments=['--mode', 'qwen-long-prefill-pair-check', '--model-dir', '@model',
            '--artifact-aggregate-sha256', pins.artifact, '--execution-path', 'cbv2-contiguous',
            '--tokens-file', '@rank/prompt.json', '--long-prompt-sha256', pins.prompt,
            '--prompt-tokens', '8192', '--chunk-size', '512', '--decode-tokens', '1',
            '--repeats', '1', '--warmups', '0', '--timeout-seconds', '300'])
