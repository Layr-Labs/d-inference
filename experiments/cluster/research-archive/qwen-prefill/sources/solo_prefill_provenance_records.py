"""Pure identity/reference checks for one frozen remote solo prefill run."""
import hashlib
import json
from pathlib import PurePosixPath
import re

BINARY = '9195a464d9d30784e7becc2c20c487847ef865696abc2d7de1c06ff18c75aaa5'
ARTIFACT = '127de76b4ef82b7aaa0acaac0ee31c784cff066eda64291f521f051469b7c24b'
CONFIGURATION = 'c8e767de4953e58352fbc1acbf6615329075ed02fe16a36b8065714d85ee4423'
ORIGIN_REFERENCE = '782138cb276748af1b4a8d9f2d5d76461ae9973a5919e4f4317035c551b2976b'
BASELINE_EVIDENCE = '54213f9c90b92033cf9ea78976f3cd8f6af355dc45930f6432a49351f97bc1a8'
ORIGIN_RECEIPT = '0afffd9b1863f785f4f3880f71c21305177f36cb825e29e506983ff0f745cfc1'
EXPECTED_INVENTORY = 'da869c797a5f37c264e4f1e1ddcf5c5f021630a9aae672dc2d2fb55ecd967a99'


def require(value, message):
    if not value:
        raise ValueError(message)


def valid_hash(value):
    require(type(value) is str and re.fullmatch('[0-9a-f]{64}', value) is not None, 'Malformed SHA256 pin')
    return value


def validate_layout(receipt):
    require(type(receipt['run_id']) is str and re.fullmatch('[0-9a-f]{32}', receipt['run_id']), 'Invalid owned run ID')
    require(type(receipt['execution_host']) is str
            and re.fullmatch('[A-Za-z0-9][A-Za-z0-9_.-]{0,127}', receipt['execution_host']), 'Invalid SSH alias')
    remote = receipt['remote_paths']
    require(set(remote) == {'root', 'run', 'native', 'controls', 'bundle', 'model'}, 'Unexpected remote layout fields')
    for value in remote.values():
        require(type(value) is str and re.fullmatch(r'/(?:[A-Za-z0-9_.-]+/)*[A-Za-z0-9_.-]+', value)
                and str(PurePosixPath(value)) == value and '..' not in PurePosixPath(value).parts,
                'Remote path is not canonical/absolute')
    require(remote['run'] == remote['root'] + '/' + receipt['run_id']
            and remote['native'] == remote['run'] + '/native'
            and remote['controls'] == remote['run'] + '/controls'
            and remote['bundle'] == remote['native'] + '/bundle', 'Owned paths differ')
    root, model = PurePosixPath(remote['root']), PurePosixPath(remote['model'])
    require(root != model and root not in model.parents and model not in root.parents, 'Run root overlaps model')
    return remote


def validate_completion(receipt):
    require(receipt['kind'] == 'remote_qwen_layer_stage_solo_prefill_launcher'
            and type(receipt['schema_version']) is int and receipt['schema_version'] == 1,
            'Wrong launcher record kind/version')
    for name in ('passed', 'native_execution_attempted', 'source_bundle_inputs_and_remote_model_unchanged_after_run',
                 'remote_pid_observations_are_not_reaping_proof'):
        require(receipt[name] is True, 'Missing successful launcher declaration: ' + name)
    for name in ('physical_two_machine_execution', 'interprocess_model_transport', 'throughput_qualification',
                 'independent_comparison_oracle_run', 'local_model_payload_verified', 'native_baseline_forward'):
        require(receipt[name] is False, 'Unexpected launcher scope: ' + name)
    require(type(receipt['native_process_count']) is int and receipt['native_process_count'] == 1
            and type(receipt['timeout_seconds']) is int and receipt['timeout_seconds'] == 180
            and receipt['primary_failure'] is None and receipt['cleanup_errors'] == []
            and receipt['post_run_errors'] == [], 'Launcher failure/bounds differ')
    execution = receipt['execution']
    require(execution['passed'] is True and type(execution['exit_code']) is int and execution['exit_code'] == 0
            and execution['local_ssh_client_reaped'] is True
            and execution['remote_process_reaping_independently_verified'] is False
            and execution['independent_comparison_oracle_run'] is False
            and type(execution['validated_outer_records']) is int and execution['validated_outer_records'] == 2
            and execution['error'] is None and execution['cancellation_reason'] is None
            and execution['cleanup_errors'] == [], 'Supervisor completion/scope differs')
    require(type(execution['local_ssh_client_pid']) is int and execution['local_ssh_client_pid'] > 0, 'Invalid local SSH PID')
    validate_layout(receipt)
    return execution


def reference_bytes(origin, descriptor, prompt, reference):
    require(len(origin) <= 128 * 1024 and hashlib.sha256(origin).hexdigest() == ORIGIN_REFERENCE,
            'Original solo reference pin differs')
    require(descriptor['baselineEvidenceFingerprint'] == BASELINE_EVIDENCE
            and descriptor['source']['artifactAggregateSHA256'] == ARTIFACT
            and descriptor['source']['sourceConfigurationSHA256'] == CONFIGURATION, 'Reference source pins differ')
    request = descriptor['request']
    require(request['promptTokenIDsSHA256'] == hashlib.sha256(','.join(map(str, prompt)).encode()).hexdigest()
            and request['promptCount'] == 65 and request['chunkSize'] == 32
            and request['outputCount'] == 1 and request['vocabularySize'] == 248320, 'Reference workload differs')
    # Model the sorted rank-config write, its parse preserving key order, then
    # rank_worker's default JSON serialization. This is not canonical DTO JSON.
    ordered = json.loads(json.dumps(descriptor, sort_keys=True, allow_nan=False))
    staged = json.dumps(ordered, allow_nan=False).encode('ascii')
    staged_hash = hashlib.sha256(staged).hexdigest()
    require(len(staged) <= 128 * 1024 and reference['origin_file_sha256'] == ORIGIN_REFERENCE
            and reference['staged_file_sha256'] == staged_hash
            and reference['baseline_evidence_sha256'] == BASELINE_EVIDENCE
            and reference['original_and_staged_bytes_identical'] is (origin == staged)
            and reference['native_baseline_forward_required'] is False
            and reference['worker_serialization'] == 'json.dumps(content), default separators/ensure_ascii, no newline',
            'Reference serialization declarations differ')
    return ordered, staged, staged_hash


def expected_rank(receipt, descriptor, staged_hash):
    remote, prompt = receipt['remote_paths'], receipt['inputs']['prompt']
    return dict(bundle=remote['bundle'], bundle_sha256=receipt['bundle_manifest_sha256'], rank=0,
        persistent=False, model_directory=remote['model'], artifact_aggregate_sha256=ARTIFACT,
        timeout_seconds=180, environment={'DARKBLOOM_BF16_WEIGHTS': '1'}, environment_files={},
        input_files={'prompt.json': prompt, 'solo-reference.json': descriptor}, arguments=[
            '--mode', 'qwen-layer-stage-solo-prefill-check', '--model-dir', '@model',
            '--artifact-aggregate-sha256', ARTIFACT, '--execution-path', 'cbv2-contiguous',
            '--tokens-file', '@rank/prompt.json', '--prompt-tokens', '65', '--chunk-size', '32',
            '--decode-tokens', '1', '--repeats', '1', '--warmups', '0', '--timeout-seconds', '180',
            '--solo-reference-file', '@rank/solo-reference.json', '--solo-reference-sha256', staged_hash,
            '--solo-baseline-evidence-sha256', BASELINE_EVIDENCE])
