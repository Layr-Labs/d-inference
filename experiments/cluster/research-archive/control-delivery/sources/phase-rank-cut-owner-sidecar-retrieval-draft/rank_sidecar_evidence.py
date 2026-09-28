"""Exact launch config and rank/history correlation; numerical execution stays opaque."""
import json
import uuid
from rank_sidecar_archives import WARNING
from sidecar_files import parse, pin, require, sha
from rank_sidecar_selection import validate_native_selection

PROFILE = 'long_prefill_8k_v1'
FLOW = 'profiled_prefill_measurement_v1'
ENVIRONMENT = {'DARKBLOOM_BF16_WEIGHTS': '1', 'DARKBLOOM_CBV2_ATTN_QUERY_BLOCK': '128', 'MLX_ENABLE_TF32': '1'}


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=False, allow_nan=False).encode()


def configuration(receipt, rank):
    layout, epoch = receipt['remote_paths'], receipt['epoch']
    bundle_hash = pin(receipt['bundle_manifest_sha256'])
    artifact = pin(receipt['artifact_aggregate_sha256'])
    prompt = pin(receipt['inputs']['prompt_file_sha256'])
    return dict(bundle=layout['bundle'], bundle_sha256=bundle_hash, rank=rank, persistent=False,
        model_directory=layout['model'], artifact_aggregate_sha256=artifact, timeout_seconds=300,
        environment=dict(ENVIRONMENT, MLX_RANK=str(rank)), environment_files={'MLX_HOSTFILE': 'hosts.json'}, input_files={},
        arguments=['--mode', 'qwen-long-prefill-rank-check', '--model-dir', '@model',
            '--artifact-aggregate-sha256', artifact, '--transport', 'loopback-test', '--epoch', epoch,
            '--execution-path', 'cbv2-contiguous', '--stage-cut', '12',
            '--stage-prefill-policy', receipt['stage_prefill_policy'],
            '--stage-logits-dtype', 'bfloat16', '--tokens-file', '@rank/prompt.json',
            '--long-prompt-sha256', prompt, '--prompt-tokens', '8192', '--chunk-size', '512',
            '--decode-tokens', '1', '--repeats', '1', '--warmups', '0', '--seed', '7',
            '--timeout-seconds', '300', '--prefill-phase-trace-file', '@rank/phase-trace.json',
            '--prefill-owner-trace-file', '@rank/owner-trace.json'])


def native_identity(raw_files, receipt, rank):
    prefix = 'rank-' + str(rank) + '/'
    raw = raw_files[prefix + 'rank.json']
    require(sha(raw) == pin(receipt['rank_configuration_sha256'][rank]), 'Rank configuration pin differs')
    # Canonical JSON keeps booleans/floating equivalents distinct from integers.
    require(canonical(parse(raw)) == canonical(configuration(receipt, rank)), 'Exact rank configuration differs')
    require(sha(raw_files[prefix + 'prompt.json']) == receipt['inputs']['prompt_file_sha256']
            and raw_files[prefix + 'hosts.json'] == json.dumps(receipt['hostfile']).encode(),
            'Saved rank raw input differs from launcher inputs')
    require(raw_files[prefix + 'stderr.log'] == WARNING, 'Rank stderr is not the exact source-bound warning')
    stdout = raw_files[prefix + 'stdout.jsonl']
    require(stdout.endswith(b'\n'), 'Incomplete rank stdout')
    lines = stdout.splitlines()
    require(len(lines) == 2 and all(lines), 'Exactly two rank records required')
    rows = [parse(line) for line in lines]
    for index, value in enumerate(rows):
        expected = dict(kind='qwen_long_prefill_rank_ready' if index == 0 else 'qwen_long_prefill_rank_report',
            schemaVersion=1, epoch=receipt['epoch'], rank=rank, worldSize=2, transport='loopback-test',
            backend='ring', flow=FLOW, envelopeVersion=4, promptFileSHA256=receipt['inputs']['prompt_file_sha256'])
        require(type(value) is dict and all(type(value.get(key)) is type(item) and value[key] == item
                for key, item in expected.items()), 'Native rank/epoch/namespace differs')
        pin(value['agreementFingerprint'])
    first, final = rows
    require(first['modelsReadyAgreementValidated'] is True and first['freshRequestStateCreated'] is False
            and all(final.get(key) is True for key in ('completed', 'correctnessOnly', 'allRequestStateRetired', 'modelReleased'))
            and all(final.get(key) is False for key in ('throughputMeasurementValid', 'modelForwardCompared', 'physicalTransferQualified')),
            'Native rank owner did not report successful diagnostic retirement')
    agreement = first['agreement']
    require(type(agreement) is dict and canonical(agreement) == canonical(final['agreement'])
            and first['agreementFingerprint'] == final['agreementFingerprint']
            and sha(b'qwen-profiled-prefill-start-agreement-v1\n' + canonical(agreement)) == first['agreementFingerprint'],
            'Native agreement changed or its fingerprint differs')
    for key, expected in dict(version=4, flow=FLOW, epoch=receipt['epoch'], profile=PROFILE,
                             schedulingPolicy=receipt['stage_prefill_policy'], nativeDType='bfloat16', logitsDType='bfloat16').items():
        require(type(agreement.get(key)) is type(expected) and agreement[key] == expected, 'Wrong agreement field: ' + key)
    fingerprint = pin(agreement['recordedRequestFingerprint'])
    request = final['request']
    require(request['fingerprint'] == fingerprint and request['request']['profile'] == PROFILE
            and str(uuid.UUID(request['request']['requestID'])) == str(uuid.UUID(hex=receipt['epoch'])),
            'Native recorded request differs from ready agreement')
    source = final['sourceLoad']
    require(type(source['stageIndex']) is int and source['stageIndex'] == rank
            and source['verifiedAggregateSHA256'] == receipt['artifact_aggregate_sha256']
            and source['sourceConfigurationSHA256'] == receipt['configuration_sha256']
            and source['storageCommitmentSHA256'] == agreement['storageCommitmentSHA256'], 'Native stage/source differs')
    require(final['arithmeticEnvironmentSHA256'] == agreement['arithmeticEnvironmentSHA256'], 'Native arithmetic identity differs')
    validate_native_selection(agreement, source, rank)
    return dict(expected_identity=dict(requestFingerprint=fingerprint, profile=PROFILE, role='rank' + str(rank)),
                agreement=agreement, agreement_fingerprint=first['agreementFingerprint'], request=request)
