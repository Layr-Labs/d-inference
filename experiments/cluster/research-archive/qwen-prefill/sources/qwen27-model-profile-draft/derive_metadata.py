#!/usr/bin/env python3
"""Replay retained JSON metadata only; never open checkpoint tensor payloads."""
import hashlib
import json
import math
import re
from collections import Counter
from pathlib import Path

HERE = Path(__file__).resolve().parent
MODEL = HERE.parent.parent / 'models/Qwen3.8-27B'
PINS = {
    'config.json': '4691da94a1b4ef415aad112ec46abebd33f8a41ad07380e486c0526eb945c1ff',
    'manifest.json': 'd1239a5bc6d26d5ce4bf87f22270e3a703f4942e3d0d779948b4f65410df6dcc',
    'weight-layout.json': '2e03d0192ebb5d392c487582a3c4d1d8466fbf483c8d18bee4f9cb298997070b',
}


def read_pinned():
    raw = {}
    for name, pin in PINS.items():
        path = MODEL / name
        with path.open('rb') as handle:
            data = handle.read(1_048_577)
        assert len(data) <= 1_048_576 and hashlib.sha256(data).hexdigest() == pin
        raw[name] = data
    return raw


def main():
    before = read_pinned()
    config, manifest, layout = [json.loads(before[n]) for n in PINS]
    t = config['text_config']
    assert t['num_hidden_layers'] == 64 and t['full_attention_interval'] == 4
    assert t['layer_types'] == ['full_attention' if (i + 1) % 4 == 0 else 'linear_attention' for i in range(64)]
    assert t['output_gate_type'] == 'swish' and not t['tie_word_embeddings']
    assert manifest['aggregate_sha256'] == 'bbd0e0adcfe74e095073fefd0b9e116e4311d606ad9989cf81f8175e8ac18463'
    assert manifest['total_size_bytes'] == sum(x['size_bytes'] for x in manifest['files'])
    assert next(x['sha256'] for x in manifest['files'] if x['path'] == 'config.json') == PINS['config.json']
    text = {n: v for n, v in layout['tensors'].items() if n.startswith('language_model.')}
    assert len(text) == 1847
    widths = {'BF16': 2, 'F16': 2, 'F32': 4, 'U32': 4}
    for value in text.values():
        assert all(type(x) is int and x > 0 for x in value['shape'])
        assert math.prod(value['shape']) * widths[value['dtype']] == value['bytes']
    source_bytes = sum(x['bytes'] for x in text.values())
    assert source_bytes == 15_132_802_048
    layer_pattern = re.compile(r'^language_model\.model\.layers\.([0-9]+)\.')

    def owner(name, cut):
        match = layer_pattern.match(name)
        if match:
            index = int(match.group(1))
            assert 0 <= index < 64
            return int(index >= cut)
        if name.startswith('language_model.model.embed_tokens.'):
            return 0
        assert name == 'language_model.model.norm.weight' or name.startswith('language_model.lm_head.')
        return 1

    g = {key: t[key] for key in ['num_hidden_layers', 'full_attention_interval', 'hidden_size',
        'num_attention_heads', 'num_key_value_heads', 'head_dim', 'linear_num_key_heads',
        'linear_num_value_heads', 'linear_key_head_dim', 'linear_value_head_dim', 'linear_conv_kernel_dim']}
    channels = 2 * t['linear_num_key_heads'] * t['linear_key_head_dim'] + t['linear_num_value_heads'] * t['linear_value_head_dim']
    conv = 4 * (t['linear_conv_kernel_dim'] - 1) * channels
    ssm = 4 * t['linear_num_value_heads'] * t['linear_value_head_dim'] * t['linear_key_head_dim']
    kv = 2 * 4 * 8193 * t['num_key_value_heads'] * t['head_dim']
    boundary = 512 * t['hidden_size'] * 4
    final_attention = 2 * 2 * 8192 * t['num_key_value_heads'] * t['head_dim'] + 4
    final_recurrent = conv // 2 + ssm

    def state_terms(layers):
        attention, recurrent = layers // 4, layers - layers // 4
        parts = {'threeRecurrentGenerationsBytes': 3 * recurrent * (conv + ssm),
                 'allKVCapacityAndOffsetsBytes': attention * (kv + 4),
                 'largestSingleHostStateComponentBytes': max(conv, ssm, kv // 2),
                 'twoBoundaryArraysBytes': 2 * boundary}
        return dict(parts, conservativeStateAndBoundaryBytes=sum(parts.values()))

    fusion = {}
    for i in range(64):
        selected = {n: v for n, v in text.items() if n.startswith('language_model.model.layers.' + str(i) + '.linear_attn.')
                    and n.split('.')[-2] in ['in_proj_qkv', 'in_proj_z', 'in_proj_b', 'in_proj_a']}
        if (i + 1) % 4:
            assert len(selected) == 12
        else:
            assert not selected
        fusion[i] = sum(x['bytes'] for x in selected.values())
    cuts = []
    for cut in range(4, 64, 4):
        stages = []
        for rank, (start, end) in enumerate([(0, cut), (cut, 64)]):
            selected = {n: v for n, v in text.items() if owner(n, cut) == rank}
            layers = end - start
            stages.append({'stageIndex': rank, 'sourceRange': [start, end], 'canonicalCount': len(selected),
                'activeBytes': sum(x['bytes'] for x in selected.values()),
                'largestSourceTensorBytes': max(x['bytes'] for x in selected.values()),
                'inertBytesFromExistingBF16StageContract': (2 if rank == 0 else 1) * t['hidden_size'] * 2,
                'expectedFinalStateComponents': (layers // 4) * 9,
                'expectedFinalStateBytes': (layers // 4) * (final_attention + 3 * final_recurrent),
                'allBanksFusionReplacementBytes': sum(fusion[i] for i in range(start, end)),
                'namedStateBudget': state_terms(layers)})
        assert sum(x['activeBytes'] for x in stages) == source_bytes
        assert sum(x['canonicalCount'] for x in stages) == 1847
        cuts.append({'cut': cut, 'stages': stages, 'computeCostStatus': 'unknown', 'executionAdmitted': False})
    dtypes = Counter()
    for v in text.values():
        dtypes[v['dtype']] += v['bytes']
    output = {
        'kind': 'registered27b_profile_metadata_derivation', 'schemaVersion': 1,
        'scope': 'Retained pinned JSON; no new tensor headers, weights, constructor or native execution',
        'metadataPins': [{'name': n, 'sha256': PINS[n], 'byteCount': len(before[n])} for n in PINS],
        'artifactAggregateDeclaration': manifest['aggregate_sha256'],
        'manifestPayloadBytes': manifest['total_size_bytes'],
        'rawHeaderTensorCount': len(layout['tensors']),
        'canonicalTextTensorCount': len(text), 'canonicalTextBytes': source_bytes,
        'excludedNamespaces': dict(Counter(n.split('.')[0] for n in layout['tensors'] if n not in text)),
        'sourceDTypeBytes': dict(dtypes), 'sourceFloat16ConversionCount': sum(v['dtype'] == 'F16' for v in text.values()),
        'largestSourceTensorBytes': max(v['bytes'] for v in text.values()),
        'geometry': g, 'vocabularySize': t['vocab_size'], 'nativeBF16BoundaryBytes': boundary // 2,
        'formulaTerms': {'convolutionBytesPerLayer': conv, 'ssmBytesPerLayer': ssm,
                        'kvCapacityBytesPerAttentionLayer': kv, 'boundaryBytes': boundary},
        'fullNamedStateBudget': state_terms(64),
        'finalState': {'components': 144, 'logicalBytes': 16 * final_attention + 48 * final_recurrent,
            'attentionComponentsPerLayer': {'kv.keys': {'shape': [1, 4, 8192, 256], 'dtype': 'bfloat16', 'bytes': (final_attention - 4) // 2},
                'kv.values': {'shape': [1, 4, 8192, 256], 'dtype': 'bfloat16', 'bytes': (final_attention - 4) // 2},
                'kv.position_offsets': {'shape': [1], 'dtype': 'int32', 'bytes': 4}},
            'recurrentComponentsPerLayer': {'conv': {'shape': [1, 3, channels], 'dtype': 'bfloat16', 'bytes': conv // 2},
                'ssm': {'shape': [1, 48, 128, 128], 'dtype': 'float32', 'bytes': ssm}}},
        'fusionReplacement': {'allBanksBytes': sum(fusion.values()), 'largestBankBytes': max(fusion.values()),
            'isPermanentDuplicateWeightClaim': False, 'isWholeProcessBound': False},
        'cuts': cuts, 'payloadVerified': False, 'nativeLoadedInventoryProven': False,
        'memorySafetyEstablished': False, 'performanceEstimated': False,
    }
    assert read_pinned() == before
    print(json.dumps(output, sort_keys=True, indent=2, allow_nan=False))


if __name__ == '__main__':
    main()
