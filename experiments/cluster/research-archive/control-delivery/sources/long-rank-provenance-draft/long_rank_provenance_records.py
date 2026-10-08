"""Pure explicit identity and command checks for the one-cohort v4 contract."""
from pathlib import PurePosixPath
import re
from long_reference_provenance_common import require

POLICIES = ('serial_v1', 'prompt_lookahead_one_v1')
FLOW = 'profiled_prefill_measurement_v1'
ARITHMETIC = {'DARKBLOOM_BF16_WEIGHTS': '1', 'DARKBLOOM_CBV2_ATTN_QUERY_BLOCK': '128', 'MLX_ENABLE_TF32': '1'}
LOOPBACK_STDERR = b'Using loopback-test transport for correctness only; timings are not cluster-performance evidence\n'


def validate_layout(receipt):
    epoch = receipt['epoch']
    require(type(epoch) is str and re.fullmatch('[0-9a-f]{32}', epoch), 'Invalid exclusive epoch')
    require(receipt['run_id'] == epoch, 'Run namespace is not the common cohort epoch')
    require(type(receipt['execution_host']) is str
            and re.fullmatch('[A-Za-z0-9][A-Za-z0-9_.-]{0,127}', receipt['execution_host']), 'Invalid SSH alias')
    remote = receipt['remote_paths']
    require(set(remote) == {'root', 'run', 'bundle', 'controls', 'model', 'rank_directories'}, 'Unexpected remote layout')
    require(type(remote['rank_directories']) is list and len(remote['rank_directories']) == 2, 'Expected two owned rank directories')
    for value in [remote[key] for key in ('root', 'run', 'bundle', 'controls', 'model')] + remote['rank_directories']:
        require(type(value) is str and re.fullmatch(r'/(?:[A-Za-z0-9_.-]+/)*[A-Za-z0-9_.-]+', value)
                and str(PurePosixPath(value)) == value and '..' not in PurePosixPath(value).parts, 'Unsafe owned path')
    require(remote['run'] == remote['root'] + '/' + epoch
            and remote['bundle'] == remote['run'] + '/bundle'
            and remote['controls'] == remote['run'] + '/controls'
            and remote['rank_directories'] == [remote['run'] + '/rank-' + str(i) for i in range(2)],
            'Remote rank paths are not the exact unique cohort namespace')
    root, model = PurePosixPath(remote['root']), PurePosixPath(remote['model'])
    require(root != model and root not in model.parents and model not in root.parents, 'Cohort overlaps model')
    return remote


def validate_hostfile(value):
    require(type(value) is list and len(value) == 2, 'Expected exactly two loopback endpoints')
    for row in value:
        require(type(row) is list and len(row) == 1 and type(row[0]) is str, 'Malformed loopback endpoint row')
        match = re.fullmatch(r'127\.0\.0\.1:([0-9]+)', row[0])
        require(match and 1 <= int(match[1]) <= 65535 and str(int(match[1])) == match[1], 'Noncanonical loopback endpoint')
    require(value[0] != value[1], 'Rank listeners must use distinct ports')
    return value


def validate_completion(receipt, pins, policy):
    require(policy in POLICIES and receipt['stage_prefill_policy'] == policy, 'Scheduling policy pin differs')
    expected = dict(kind='remote_qwen_long_prefill_rank_launcher', schema_version=1, native_rank_count=2,
        transport='loopback-test', backend='ring', flow=FLOW, envelope_version=4,
        stage_logits_dtype='bfloat16', native_timeout_seconds=300,
        expected_native_sha256=pins.native, artifact_aggregate_sha256=pins.artifact,
        configuration_sha256=pins.configuration)
    for key, value in expected.items():
        require(type(receipt[key]) is type(value) and receipt[key] == value, 'Launcher identity differs: ' + key)
    for key in ('passed', 'native_execution_attempted', 'stage_model_forward_requested', 'timing_requested',
                'timing_diagnostic_only', 'source_bundle_raw_inputs_and_remote_model_unchanged_after_run',
                'remote_pid_observations_are_not_reaping_proof'):
        require(receipt[key] is True, 'Missing launcher success flag: ' + key)
    for key in ('physical_two_machine_execution', 'throughput_qualification', 'independent_execution_oracle_run',
                'full_reference_forward_requested', 'model_payload_copies_created', 'local_model_payload_verified'):
        require(receipt[key] is False, 'Unexpected launcher scope: ' + key)
    require(type(receipt['parent_timeout_seconds']) is int and 1 <= receipt['parent_timeout_seconds'] <= 330
            and receipt['primary_failure'] is None and receipt['cleanup_errors'] == []
            and receipt['post_run_errors'] == [], 'Launcher failure or parent deadline differs')
    cohort = receipt['cohort']
    require(cohort['passed'] is True and cohort['exit_codes'] == [0, 0]
            and all(type(x) is int for x in cohort['exit_codes'])
            and cohort['local_ssh_clients_reaped'] == [True, True]
            and all(x is True for x in cohort['local_ssh_clients_reaped'])
            and cohort['remote_process_reaping_independently_verified'] is False
            and cohort['cancellation_reason'] is None and cohort['error'] is None
            and cohort['cleanup_errors'] == [], 'Cohort completion differs')
    pids = cohort['local_ssh_client_pids']
    require(type(pids) is list and len(pids) == 2 and all(type(pid) is int and pid > 0 for pid in pids)
            and len(set(pids)) == 2, 'Expected two distinct reaped local SSH clients')
    validation = cohort['validation']
    require(validation == dict(records_per_rank=[2, 2], shared_agreement_matches=True, nested_execution_oracle_run=False)
            and all(type(x) is int for x in validation['records_per_rank'])
            and validation['shared_agreement_matches'] is True and validation['nested_execution_oracle_run'] is False,
            'Saved outer-only native record admission differs')
    validate_layout(receipt)
    return cohort


def expected_rank(receipt, pins, rank):
    require(type(rank) is int and rank in (0, 1), 'Invalid expected rank')
    remote = validate_layout(receipt)
    scheduling = receipt['stage_prefill_policy']
    require(scheduling in POLICIES, 'Explicit admitted scheduling policy required')
    return dict(bundle=remote['bundle'], bundle_sha256=receipt['bundle_manifest_sha256'], rank=rank,
        persistent=False, model_directory=remote['model'], artifact_aggregate_sha256=pins.artifact,
        timeout_seconds=300, environment=dict(ARITHMETIC, MLX_RANK=str(rank)),
        environment_files={'MLX_HOSTFILE': 'hosts.json'}, input_files={},
        arguments=['--mode', 'qwen-long-prefill-rank-check', '--model-dir', '@model',
            '--artifact-aggregate-sha256', pins.artifact, '--transport', 'loopback-test', '--epoch', receipt['epoch'],
            '--execution-path', 'cbv2-contiguous', '--stage-prefill-policy', scheduling,
            '--stage-logits-dtype', 'bfloat16', '--tokens-file', '@rank/prompt.json',
            '--long-prompt-sha256', pins.prompt, '--prompt-tokens', '8192', '--chunk-size', '512',
            '--decode-tokens', '1', '--repeats', '1', '--warmups', '0', '--seed', '7', '--timeout-seconds', '300'])
