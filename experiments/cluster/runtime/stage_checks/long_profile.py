"""Public registered-artifact/profile constants matching native admission."""
import re

COMMANDS = ('long-prefill-ranks', 'long-prefill-solo')
POLICIES = ('serial_v1', 'prompt_lookahead_one_v1')
PROFILE = 'long_prefill_8k_v1'
PROFILE_SHA256 = '2b7f484488df61c4f6042acfb472a8099828c8a6246819501c88d4f6e07bcc0b'
ARTIFACT = '127de76b4ef82b7aaa0acaac0ee31c784cff066eda64291f521f051469b7c24b'
CONFIGURATION = 'c8e767de4953e58352fbc1acbf6615329075ed02fe16a36b8065714d85ee4423'
VOCABULARY = 248320
NATIVE_TIMEOUT = 300
MAX_PARENT_TIMEOUT = 330
REQUIRED_ENVIRONMENT = {'DARKBLOOM_BF16_WEIGHTS': '1',
    'DARKBLOOM_CBV2_ATTN_QUERY_BLOCK': '128', 'MLX_ENABLE_TF32': '1'}


def is_sha256(value):
    return type(value) is str and re.fullmatch('[0-9a-f]{64}', value) is not None
