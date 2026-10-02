"""Closed, source-derived configuration; never execute archived launcher code."""
import json
from sidecar_files import pin, require

ARTIFACT = '127de76b4ef82b7aaa0acaac0ee31c784cff066eda64291f521f051469b7c24b'
ENVIRONMENT = {'DARKBLOOM_BF16_WEIGHTS': '1',
               'DARKBLOOM_CBV2_ATTN_QUERY_BLOCK': '128', 'MLX_ENABLE_TF32': '1'}


def require_configuration(value, receipt):
    paths = receipt['remote_paths']
    for key in ('bundle', 'model'):
        require(type(paths[key]) is str and paths[key].startswith('/') and '\x00' not in paths[key],
                'Missing absolute declared bundle/model path')
    require(paths['bundle'] == paths['run'] + '/bundle', 'Bundle is outside the owned run')
    prompt_sha256 = pin(receipt['inputs']['prompt_file_sha256'])
    expected = dict(bundle=paths['bundle'], bundle_sha256=pin(receipt['bundle_manifest_sha256']),
        rank=0, persistent=False, model_directory=paths['model'], artifact_aggregate_sha256=ARTIFACT,
        timeout_seconds=300, environment=dict(ENVIRONMENT), environment_files={}, input_files={},
        arguments=['--mode', 'qwen-long-prefill-solo-check', '--model-dir', '@model',
            '--artifact-aggregate-sha256', ARTIFACT, '--execution-path', 'cbv2-contiguous',
            '--tokens-file', '@rank/prompt.json', '--long-prompt-sha256', prompt_sha256,
            '--prompt-tokens', '8192', '--chunk-size', '512', '--decode-tokens', '1',
            '--repeats', '1', '--warmups', '0', '--timeout-seconds', '300',
            '--prefill-phase-trace-file', '@rank/phase-trace.json',
            '--prefill-owner-trace-file', '@rank/owner-trace.json'])
    # JSON keeps integer, Boolean and floating equivalents distinct.
    encode = lambda item: json.dumps(item, sort_keys=True, separators=(',', ':'), allow_nan=False)
    require(encode(value) == encode(expected), 'Exact solo owner configuration differs')
