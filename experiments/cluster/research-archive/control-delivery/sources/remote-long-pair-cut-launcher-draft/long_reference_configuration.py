"""Fixed native request and byte-preserving staging contract."""
from long_reference_inputs import ARTIFACT, is_sha256, require
from long_pair_cut import STAGE_CUT

NATIVE_TIMEOUT_SECONDS = 300
MAX_PARENT_SECONDS = 330
REQUIRED_ENVIRONMENT = {'DARKBLOOM_BF16_WEIGHTS': '1',
                        'DARKBLOOM_CBV2_ATTN_QUERY_BLOCK': '128', 'MLX_ENABLE_TF32': '1'}


def timeout(value):
    require(type(value) is int and 1 <= value <= MAX_PARENT_SECONDS,
            'Parent timeout must be an integer from 1 through 330 seconds')


def configuration(bundle, bundle_hash, model, prompt_sha256):
    require(is_sha256(bundle_hash) and is_sha256(prompt_sha256), 'Explicit bundle and raw prompt pins required')
    return dict(bundle=str(bundle), bundle_sha256=bundle_hash, rank=0, persistent=False,
        model_directory=str(model), artifact_aggregate_sha256=ARTIFACT,
        timeout_seconds=NATIVE_TIMEOUT_SECONDS, environment=dict(REQUIRED_ENVIRONMENT),
        environment_files={}, input_files={},
        arguments=['--mode', 'qwen-long-prefill-pair-check', '--model-dir', '@model',
            '--artifact-aggregate-sha256', ARTIFACT, '--execution-path', 'cbv2-contiguous',
            '--stage-cut', str(STAGE_CUT),
            '--tokens-file', '@rank/prompt.json', '--long-prompt-sha256', prompt_sha256,
            '--prompt-tokens', '8192', '--chunk-size', '512', '--decode-tokens', '1',
            '--repeats', '1', '--warmups', '0', '--timeout-seconds', str(NATIVE_TIMEOUT_SECONDS)])


def require_rank_configuration(value, bundle, bundle_hash, model, prompt_sha256):
    require(value == configuration(bundle, bundle_hash, model, prompt_sha256),
            'Rank configuration differs from the fixed raw-prompt/environment/native contract')
