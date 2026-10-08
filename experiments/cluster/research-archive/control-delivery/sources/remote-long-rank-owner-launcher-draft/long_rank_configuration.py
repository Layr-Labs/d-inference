"""Exact new v4 rank argv; the unchanged worker never rewrites staged inputs."""
import re
from long_reference_inputs import ARTIFACT, is_sha256, require

NATIVE_TIMEOUT_SECONDS, MAX_PARENT_SECONDS = 300, 330
POLICIES = ('serial_v1', 'prompt_lookahead_one_v1')
REQUIRED_ENVIRONMENT = {'DARKBLOOM_BF16_WEIGHTS': '1',
    'DARKBLOOM_CBV2_ATTN_QUERY_BLOCK': '128', 'MLX_ENABLE_TF32': '1'}


def timeout(value):
    require(type(value) is int and 1 <= value <= MAX_PARENT_SECONDS, 'Parent timeout must be 1 through 330 seconds')


def policy(value):
    require(value in POLICIES, 'Explicit native serial_v1 or prompt_lookahead_one_v1 policy required')
    return value


def hostfile(value):
    require(type(value) is list and len(value) == 2, 'Two loopback endpoints required')
    for row in value:
        require(type(row) is list and len(row) == 1 and type(row[0]) is str, 'Invalid loopback row')
        match = re.fullmatch(r'127\.0\.0\.1:(\d+)', row[0])
        require(match is not None and 1 <= int(match[1]) <= 65535 and str(int(match[1])) == match[1], 'Invalid loopback endpoint')
    require(value[0] != value[1], 'Loopback endpoints must differ')
    return value


def configuration(bundle, bundle_hash, model, prompt_sha256, rank, epoch, scheduling):
    policy(scheduling)
    require(type(rank) is int and rank in (0, 1) and type(epoch) is str
            and re.fullmatch('[0-9a-f]{32}', epoch) is not None, 'Invalid rank/epoch')
    require(is_sha256(bundle_hash) and is_sha256(prompt_sha256), 'Bundle and raw prompt pins required')
    return dict(bundle=str(bundle), bundle_sha256=bundle_hash, rank=rank, persistent=False,
        model_directory=str(model), artifact_aggregate_sha256=ARTIFACT, timeout_seconds=NATIVE_TIMEOUT_SECONDS,
        environment=dict(REQUIRED_ENVIRONMENT, MLX_RANK=str(rank)),
        environment_files={'MLX_HOSTFILE': 'hosts.json'}, input_files={},
        arguments=['--mode', 'qwen-long-prefill-rank-check', '--model-dir', '@model',
            '--artifact-aggregate-sha256', ARTIFACT, '--transport', 'loopback-test', '--epoch', epoch,
            '--execution-path', 'cbv2-contiguous', '--stage-prefill-policy', scheduling,
            '--stage-logits-dtype', 'bfloat16', '--tokens-file', '@rank/prompt.json',
            '--long-prompt-sha256', prompt_sha256, '--prompt-tokens', '8192', '--chunk-size', '512',
            '--decode-tokens', '1', '--repeats', '1', '--warmups', '0', '--seed', '7',
            '--timeout-seconds', str(NATIVE_TIMEOUT_SECONDS),
            '--prefill-phase-trace-file', '@rank/phase-trace.json',
            '--prefill-owner-trace-file', '@rank/owner-trace.json'])


def require_configuration(value, bundle, bundle_hash, model, prompt_sha256, rank, epoch, scheduling):
    require(value == configuration(bundle, bundle_hash, model, prompt_sha256, rank, epoch, scheduling),
            'Rank configuration differs from exact v4 raw-input/arithmetic/epoch contract')
