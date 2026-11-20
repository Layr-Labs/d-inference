"""Model identities for the explicitly supported synthetic fixtures."""

MODEL_FAMILIES = ('qwen35', 'gemma4')
GEMMA_PROFILES = {'gemma-moe': 'mixed-w4w8g64', 'gemma-moe-w8': 'w8g64'}
SYNTHETIC_PROFILES = ('tiny', 'qwen9-heads', 'qwen27-heads', 'qwen-moe', *GEMMA_PROFILES)
CBV2_SYNTHETIC_PROFILES = ('tiny', 'qwen9-heads', 'qwen27-heads')


def synthetic_identity(workload):
    profile = workload['synthetic_profile']
    family = 'gemma4' if profile in GEMMA_PROFILES else 'qwen35'
    quantization = GEMMA_PROFILES.get(profile, 'w4g64')
    return dict(modelFamily=family, model=f'synthetic-{family}-{quantization}-seed-{workload["seed"]}',
                vocabularySize=512, layerCount=4,
                feedForwardKind='moe' if profile == 'qwen-moe' or profile in GEMMA_PROFILES else 'dense')
