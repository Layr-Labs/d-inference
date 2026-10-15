"""Closed metadata from pinned QwenDenseRegisteredSpecification/ModelDefinition.

These values grant no native execution or resource permit. No tensor payload is
opened here, and no Plan or Foundation serialization fingerprint is reproduced.
"""
from dataclasses import dataclass
from binding_common import require


@dataclass(frozen=True)
class Profile:
    model: str
    identifier: str
    artifact: str
    configuration: str
    manifest: str
    layers: int
    hidden: int
    source_bytes: int
    tensor_count: int
    largest_tensor_bytes: int
    value_heads: int
    conv_channels: int
    cuts: tuple


PROFILES = {
    'registered_qwen35_9b': Profile('registered_qwen35_9b', 'registered_qwen35_9b_greedy_generation_v1',
        '127de76b4ef82b7aaa0acaac0ee31c784cff066eda64291f521f051469b7c24b',
        'c8e767de4953e58352fbc1acbf6615329075ed02fe16a36b8065714d85ee4423',
        '4f2735026cc7b40ee2c886ee53fb8755816c0001c4c69c141a61d5f56ff22aa4',
        32, 4096, 5_038_041_600, 927, 508_559_360, 32, 8192, (4, 8, 12, 16)),
    'registered_qwen38_27b': Profile('registered_qwen38_27b', 'registered_qwen38_27b_greedy_generation_v1',
        'bbd0e0adcfe74e095073fefd0b9e116e4311d606ad9989cf81f8175e8ac18463',
        '4691da94a1b4ef415aad112ec46abebd33f8a41ad07380e486c0526eb945c1ff',
        'd1239a5bc6d26d5ce4bf87f22270e3a703f4942e3d0d779948b4f65410df6dcc',
        64, 5120, 15_132_802_048, 1847, 635_699_200, 48, 10240, (4, 8, 12, 16, 32)),
}


def registered_profile(model):
    require(type(model) is str and model in PROFILES, 'Unknown registered reference model')
    return PROFILES[model]
