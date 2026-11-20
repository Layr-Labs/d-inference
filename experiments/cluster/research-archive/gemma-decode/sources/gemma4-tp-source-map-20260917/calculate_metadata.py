#!/usr/bin/env python3
"""Small retained-JSON arithmetic only. No model payload, runtime or hardware reads."""
import collections
import hashlib
import json
from pathlib import Path

ROOT = Path('/Users/developer/DarkbloomDev/cluster-research')
SOURCE = ROOT / 'gemma4-26b-distributed-artifact-20260915'
OUT = Path(__file__).resolve().parent

def digest(data):
    return hashlib.sha256(data).hexdigest()

def main():
    raw = (SOURCE / 'tensor-inventory.json').read_bytes()
    tensors = json.loads(raw)['tensors']
    config_raw = (SOURCE / 'metadata/config.json').read_bytes()
    config = json.loads(config_raw)
    text = config['text_config']
    assert (text['hidden_size'], text['num_hidden_layers'], text['num_experts'],
            text['top_k_experts'], text['intermediate_size'], text['moe_intermediate_size']) == (
            2816, 30, 128, 8, 2112, 704)
    assert text['num_kv_shared_layers'] == 0 and text['hidden_size_per_layer_input'] == 0
    widths = {'BF16': 2, 'F16': 2, 'F32': 4, 'U32': 4}
    totals, counts = collections.Counter(), collections.Counter()
    attention_norms = 0
    for name, item in tensors.items():
        elements = 1
        for value in item['shape']:
            assert isinstance(value, int) and value > 0
            elements *= value
        byte_count = elements * widths[item['dtype']]
        assert byte_count == item['data_offsets'][1] - item['data_offsets'][0]
        if not name.startswith('language_model.'):
            kind = 'excluded_nontext'
        elif '.self_attn.' in name:
            kind = 'attention'
            if '.q_norm.' in name or '.k_norm.' in name:
                attention_norms += byte_count
        elif '.experts.' in name:
            kind = 'routed_experts'
        elif '.mlp.' in name:
            kind = 'dense_mlp'
        elif '.router.' in name:
            kind = 'router'
        elif '.embed_tokens.' in name:
            kind = 'embedding'
        else:
            kind = 'other_text'
        totals[kind] += byte_count
        counts[kind] += 1
    text_bytes = sum(v for k, v in totals.items() if k != 'excluded_nontext')
    nonexpert = text_bytes - totals['routed_experts']
    replicated_ffn = text_bytes - totals['routed_experts'] - totals['dense_mlp']
    ffn = [replicated_ffn + totals['dense_mlp'] * dense // 2112
           + totals['routed_experts'] * expert // 704
           for dense, expert in [(1024, 320), (1088, 384)]]
    attention_saving = (totals['attention'] - attention_norms) // 2
    ep64 = [nonexpert + totals['routed_experts'] * n // 128 for n in [64, 64]]
    ep48 = [nonexpert + totals['routed_experts'] * n // 128 for n in [48, 80]]
    policies = {
        'existing_ffn_width_tp': ffn,
        'prospective_head_plus_ffn_width_tp': [n - attention_saving for n in ffn],
        'whole_expert_ep_64_64_replicated_nonexpert': ep64,
        'whole_expert_ep_48_80_replicated_nonexpert': ep48,
    }
    sizes = lambda value: {'bytes': value, 'GB_decimal': value / 1_000_000_000,
                           'GiB_binary': value / (1024 ** 3)}
    costs = []
    for rows in [1, 32, 256]:
        for scalar_bytes in [2, 4]:
            boundary = rows * 2816 * scalar_bytes
            costs.append({
                'rows': rows, 'scalarBytes': scalar_bytes,
                'oneHiddenBoundaryBytes': boundary,
                'ffnTP_perDirectionLogicalBytes_30Layers': 60 * boundary,
                'headAndFFNTP_perDirectionLogicalBytes_30Layers': 90 * boundary,
                'epSymmetricAssignments_bidirectionalLogicalBytes_30Layers': 30 * 8 * boundary,
                'epSymmetricAssignments_maxOneDirectionBytes_30Layers': 30 * 8 * boundary,
                'epOwnerGatherBroadcast_maxBidirectionalBytes_30Layers': 30 * 9 * boundary,
                'layerPipeline_oneWayMainBoundaryBytes': boundary,
            })
    result = {
        'schema': 'gemma26b_tp_metadata_costs_v1',
        'scope': 'source-derived arithmetic; not runtime memory, throughput or numerical qualification',
        'metadataInputs': {
            'inventory': {'path': str(SOURCE / 'tensor-inventory.json'), 'sha256': digest(raw)},
            'config': {'path': str(SOURCE / 'metadata/config.json'), 'sha256': digest(config_raw)},
        },
        'inventoryProvenance': json.loads(raw)['source'],
        'counts': dict(counts), 'categoryBytes': dict(totals),
        'textStoredWeights': sizes(text_bytes),
        'replicatedNonexpertStoredWeights': sizes(nonexpert),
        'attentionNormsReplicatedBytes': attention_norms,
        'headTPProjectionSavingPerRankBytes': attention_saving,
        'expertBytesPerLayer': totals['routed_experts'] // 30,
        'expertBytesPerExpertPerLayer': totals['routed_experts'] // 30 // 128,
        'prospectiveStoredWeights': {k: [sizes(n) for n in v] for k, v in policies.items()},
        'logicalCommunicationExamples': costs,
        'costExclusions': ['control/routing records', 'native RDMA frame rounding',
            'AEAD framing and copies', 'transport staging', 'KV/ring capacity',
            'prefill output-tail specialization', 'attention/FFN scratch',
            'FP32 quantization metadata cache', 'allocator slack', 'host runtime and evidence'],
        'fixedTopology': {'layers': 30, 'hidden': 2816, 'slidingLayers': 25,
            'fullLayers': 5, 'slidingWindow': 1024, 'topK': 8},
    }
    destination = OUT / 'metadata-costs.json'
    with destination.open('x') as handle:
        json.dump(result, handle, indent=2, sort_keys=True)
        handle.write('\n')

if __name__ == '__main__':
    main()
