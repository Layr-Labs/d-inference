"""Source-derived CPU constants and request/state geometry; no native imports."""
import hashlib
import json
import math
import struct
import uuid

PROFILE = 'long_prefill_8k_v1'
PROFILE_SHA = '2b7f484488df61c4f6042acfb472a8099828c8a6246819501c88d4f6e07bcc0b'
ENVIRONMENT = {'DARKBLOOM_CBV2_ATTN_QUERY_BLOCK': '128', 'DARKBLOOM_BF16_WEIGHTS': '1', 'MLX_ENABLE_TF32': '1'}
DEFAULT_BINDINGS = {
    'MLX_METAL_GPU_ARCH': 'detect actual Metal device architecture; no override',
    'MLX_SDPA_BLOCKS': 'source default 0; native adaptive block selection',
    'MLX_ENABLE_TF32': 'explicit 1 matches pinned source default; permits eligible NAX paths',
    'DARKBLOOM_BF16_WEIGHTS': 'explicit 1 converts stored Float16 tensors to BFloat16 before subsequent arithmetic',
    'DARKBLOOM_CBV2_ATTN_QUERY_BLOCK': 'explicit 128 matches pinned source default; chunk512 uses four query blocks',
}


def require(value, message):
    if not value: raise ValueError(message)


def sha(raw): return hashlib.sha256(raw).hexdigest()


def canonical(value): return json.dumps(value, sort_keys=True, separators=(',', ':'), allow_nan=False).encode()


def exact(actual, expected, label):
    require(canonical(actual) == canonical(expected), label)


def integer(value, low, high, label):
    require(type(value) is int and low <= value <= high, label)
    return value


def fingerprint(value, label):
    require(type(value) is str and len(value) == 64 and all(c in '0123456789abcdef' for c in value), label)
    return value


def configuration(dtype):
    # SyntheticConfiguration.swift plus the explicit eight-layer/profile fixture.
    text = dict(model_type='qwen3_5_text', hidden_size=128, num_hidden_layers=8, intermediate_size=256,
        num_attention_heads=4, num_key_value_heads=2, head_dim=64,
        linear_num_key_heads=2, linear_num_value_heads=2, linear_key_head_dim=128, linear_value_head_dim=128,
        linear_conv_kernel_dim=4, full_attention_interval=4, vocab_size=512, tie_word_embeddings=False,
        max_position_embeddings=8193, mtp_num_hidden_layers=0,
        quantization=dict(bits=4, group_size=64, mode='affine'), cluster_fixture_dtype=dtype,
        cluster_fixture_profile='tiny-' + PROFILE,
        layer_types=['linear_attention'] * 3 + ['full_attention'] + ['linear_attention'] * 3 + ['full_attention'])
    if dtype == 'bfloat16':
        quantization = text.pop('quantization')
        return dict(model_type='qwen3_5', text_config=text, quantization=quantization)
    require(dtype == 'float32', 'Unknown fixture dtype')
    return text


def prompt(count): return [3 + ((index * 17 + 7) % 509) for index in range(count)]


def frames(count):
    return [dict(sequence=i, phase='prefill', tokenOffset=offset, tokenCount=min(512, count - offset),
                 finalPromptChunk=offset + 512 >= count) for i, offset in enumerate(range(0, count, 512))]


def request_fingerprint(spec):
    return sha('\n'.join(['qwen-stage-profiled-prefill-request-v1', PROFILE, PROFILE_SHA,
        spec['requestID'].lower(), 'batch=1', 'prompt=' + str(spec['promptCount']), 'chunk=512', 'output=1']).encode())


def recorded_fingerprint(spec):
    return sha('\n'.join(['qwen-layer-stage-profiled-prefill-recorded-request-v1', PROFILE, PROFILE_SHA,
        request_fingerprint(spec), 'vocabulary=512', 'prompt=' + ','.join(map(str, prompt(spec['promptCount']))), 'teacher=']).encode())


def validate_spec(spec, count, seen_ids):
    require(type(spec) is dict and set(spec) == {'profile', 'requestID', 'batchSize', 'promptCount', 'chunkSize', 'outputCount'},
            'Profiled request fields differ')
    identity = spec['requestID']
    require(type(identity) is str and str(uuid.UUID(identity)) == identity.lower(), 'Malformed request UUID')
    require(identity.lower() not in seen_ids, 'Reused request UUID across lifecycle/parity')
    seen_ids.add(identity.lower())
    exact({key: value for key, value in spec.items() if key != 'requestID'},
          dict(profile=PROFILE, batchSize=1, promptCount=count, chunkSize=512, outputCount=1), 'Request geometry/profile differs')


def state_bytes(dtype, frontier):
    # Six conv [1,3,768] + F32 SSM [1,2,128,128]; two native K/V
    # layers [1,2,T,64], with one Int32 position offset per attention layer.
    return (841728 + 2048 * frontier + 8) if dtype == 'float32' else (814080 + 1024 * frontier + 8)


def native_logit_bytes(values, dtype):
    require(type(values) is list and len(values) == 512, 'Final logits must contain all 512 values')
    raw = bytearray()
    for value in values:
        require(type(value) in (int, float) and math.isfinite(value), 'Nonfinite or nonnumeric logit')
        packed = struct.pack('<f', value)
        if dtype == 'bfloat16':
            require(packed[:2] == b'\0\0', 'BF16 logit lost its exact native representability')
            packed = packed[2:]
        raw.extend(packed)
    return bytes(raw)
