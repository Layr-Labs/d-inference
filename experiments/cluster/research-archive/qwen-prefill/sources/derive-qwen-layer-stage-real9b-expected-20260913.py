#!/usr/bin/env python3
"""Independent pinned Qwen9B geometry/inventory oracle; reads headers, never payloads."""
import argparse
from collections import Counter
import hashlib
import json
import math
from pathlib import Path
import re
import sys
sys.dont_write_bytecode = True
ROOT = Path('/Users/developer/DarkbloomDev/cluster-research')
MODEL = Path('/Users/developer/DarkbloomDev/models/Qwen3.5-9B')
ARCHIVE = ROOT / 'runs/qwen-layer-stage-lifecycle-fix1-20260913'
OUTPUT = ROOT / 'qwen-layer-stage-real9b-expected-20260913.json'
AGGREGATE = '127de76b4ef82b7aaa0acaac0ee31c784cff066eda64291f521f051469b7c24b'
MANIFEST = '4f2735026cc7b40ee2c886ee53fb8755816c0001c4c69c141a61d5f56ff22aa4'
CONFIG = 'c8e767de4953e58352fbc1acbf6615329075ed02fe16a36b8065714d85ee4423'
INDEX = 'f3753fc5d26bcc0b257c152289b4fd7a20d7c8b0e59292e34a01064fa43018ff'
SOURCE_MANIFEST = 'cbac16c1fac0442785773007cc8fab734eafc5a2773e0a282eca11910d509e1a'
HEADERS = {
    'model-00001-of-00002.safetensors': (157678, '8c72349d130acb1ed8896292899b31b3d8caa2f261e0c024a83c9356f3c20185'),
    'model-00002-of-00002.safetensors': (818, 'aede7f2fd9eb9192e697bb439f91e1672fcad3777214956ec81be9b6d5b7d734'),
    'mtp-00001.safetensors': (3256, '16167d58d71332702ae727238895e3bea41c1e4ca02160fa8f805b317d3db915'),
}
DTYPES = {'BF16': ('bfloat16', 2), 'F16': ('float16', 2), 'F32': ('float32', 4), 'U32': ('uint32', 4)}
PREFIX = 'language_model.'
LAYER = re.compile(r'language_model\.model\.layers\.(\d+)\.(.+)')


def require(ok, message):
    if not ok:
        raise ValueError(message)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=False, allow_nan=False).encode()


def parse(data):
    def unique(items):
        result = {}
        for k, v in items:
            require(k not in result, 'Duplicate metadata key')
            result[k] = v
        return result
    return json.loads(data, object_pairs_hook=unique, parse_constant=lambda _: require(False, 'Nonfinite metadata'))


def pinned_json(path, expected):
    data = path.read_bytes()
    require(digest(data) == expected, 'Pinned metadata changed: ' + str(path))
    return parse(data)


def expected_shapes(c):
    """Derive dense quantized parameter schema directly from model dimensions."""
    h, intermediate, vocab = c['hidden_size'], c['intermediate_size'], c['vocab_size']
    group, pack = 64, 8
    result = {}
    def add(name, shape, dtype='BF16'):
        require(name not in result, 'Duplicate expected parameter')
        result[name] = (shape, dtype)
    def affine(name, rows, inputs):
        require(inputs % group == 0, 'Quantization input width misaligned')
        add(name + '.weight', [rows, inputs // pack], 'U32')
        for suffix in ['scales', 'biases']:
            add(name + '.' + suffix, [rows, inputs // group])
    affine(PREFIX + 'model.embed_tokens', vocab, h)
    affine(PREFIX + 'lm_head', vocab, h)
    add(PREFIX + 'model.norm.weight', [h])
    for layer in range(c['num_hidden_layers']):
        p = PREFIX + f'model.layers.{layer}.'
        for norm in ['input_layernorm', 'post_attention_layernorm']:
            add(p + norm + '.weight', [h])
        for projection in ['gate_proj', 'up_proj']:
            affine(p + 'mlp.' + projection, intermediate, h)
        affine(p + 'mlp.down_proj', h, intermediate)
        if (layer + 1) % c['full_attention_interval'] == 0:
            heads, kv, d = c['num_attention_heads'], c['num_key_value_heads'], c['head_dim']
            for name, rows in [('q_proj', heads * d * 2), ('k_proj', kv * d), ('v_proj', kv * d)]:
                affine(p + 'self_attn.' + name, rows, h)
            affine(p + 'self_attn.o_proj', h, heads * d)
            for norm in ['q_norm', 'k_norm']:
                add(p + 'self_attn.' + norm + '.weight', [d])
        else:
            keys = c['linear_num_key_heads'] * c['linear_key_head_dim']
            values = c['linear_num_value_heads'] * c['linear_value_head_dim']
            for name, rows in [('in_proj_qkv', 2 * keys + values), ('in_proj_z', values),
                    ('in_proj_a', c['linear_num_value_heads']), ('in_proj_b', c['linear_num_value_heads'])]:
                affine(p + 'linear_attn.' + name, rows, h)
            affine(p + 'linear_attn.out_proj', h, values)
            add(p + 'linear_attn.conv1d.weight', [2 * keys + values, c['linear_conv_kernel_dim'], 1])
            add(p + 'linear_attn.norm.weight', [c['linear_value_head_dim']])
            add(p + 'linear_attn.dt_bias', [c['linear_num_value_heads']])
            add(p + 'linear_attn.A_log', [c['linear_num_value_heads']], 'F32')
    return result


def source_headers(manifest, index):
    files = {x['path']: x for x in manifest['files']}
    require({k for k, v in files.items() if v['role'] == 'weight'} == set(HEADERS), 'Weight file inventory changed')
    tensors, identities = {}, []
    for name, (expected_length, expected_digest) in sorted(HEADERS.items()):
        path = MODEL / name
        require(path.stat().st_size == files[name]['size_bytes'], 'Weight file length changed')
        with path.open('rb') as stream:
            prefix = stream.read(8)
            length = int.from_bytes(prefix, 'little')
            require(len(prefix) == 8 and length == expected_length, 'Safetensor header size differs')
            header = stream.read(length)
        require(len(header) == length and digest(prefix + header) == expected_digest, 'Safetensor header identity differs')
        parsed = parse(header)
        parsed.pop('__metadata__', None)
        end = 0
        for key, value in sorted(parsed.items(), key=lambda kv: kv[1]['data_offsets'][0]):
            require(set(value) == {'shape', 'dtype', 'data_offsets'} and value['dtype'] in DTYPES, 'Unsupported tensor header')
            shape, offsets = value['shape'], value['data_offsets']
            require(all(type(d) is int and d > 0 for d in shape), 'Invalid tensor shape')
            count = math.prod(shape) * DTYPES[value['dtype']][1]
            require(offsets == [end, end + count], 'Header payload ranges overlap, have holes or wrong byte count')
            end += count
            require(key not in tensors and index['weight_map'].get(key) == name, 'Duplicate name or index/header disagreement')
            tensors[key] = dict(value, file=name)
        require(8 + length + end == files[name]['size_bytes'], 'Header ranges do not exhaust declared file')
        identities.append(dict(path=name, tensorCount=len(parsed), fileSizeBytes=files[name]['size_bytes'],
            fileSHA256ClaimedByPinnedManifest=files[name]['sha256'], headerJSONBytes=length,
            headerJSONSHA256=digest(header), lengthPrefixedHeaderSHA256=expected_digest, payloadRead=False))
    require(set(index['weight_map']) == set(tensors), 'Index/header tensor coverage differs')
    return tensors, identities


def layout(entries):
    return digest('\n'.join(sorted(f"{x['localName']}:{x['loadedDType']}:{x['shape']}" for x in entries)).encode())


def state_frames(c):
    frames = []
    for tokens in [32, 64, 65, 66, 67, 68]:
        entries = []
        def add(layer, component, shape, dtype, width):
            entries.append(dict(globalLayerIndex=layer, stageIndex=layer // 16, localLayerIndex=layer % 16,
                component=component, shape=shape, dtype=dtype, byteCount=math.prod(shape) * width))
        for layer in range(c['num_hidden_layers']):
            if (layer + 1) % c['full_attention_interval'] == 0:
                for component in ['kv.keys', 'kv.values']:
                    add(layer, component, [1, c['num_key_value_heads'], tokens, c['head_dim']], 'bfloat16', 2)
                add(layer, 'kv.position_offsets', [1], 'int32', 4)
            else:
                conv = 2 * c['linear_num_key_heads'] * c['linear_key_head_dim'] + c['linear_num_value_heads'] * c['linear_value_head_dim']
                add(layer, 'conv', [1, c['linear_conv_kernel_dim'] - 1, conv], 'bfloat16', 2)
                add(layer, 'ssm', [1, c['linear_num_value_heads'], c['linear_value_head_dim'], c['linear_key_head_dim']], 'float32', 4)
        entries.sort(key=lambda x: (x['globalLayerIndex'], x['component']))
        sums = [sum(x['byteCount'] for x in entries if x['stageIndex'] == i) for i in range(2)]
        require(len(entries) == 72 and sums[0] == sums[1] and sum(sums) == 51511328 + 32768 * tokens,
            'Independent state accounting mismatch')
        frames.append(dict(committedTokens=tokens, fullEntryCount=72, stageEntryCounts=[36, 36],
            fullStateBytes=sum(sums), stageStateBytes=sums, entries=entries))
    return frames


def derive():
    manifest = pinned_json(MODEL / 'manifest.json', MANIFEST)
    require(manifest['aggregate_sha256'] == AGGREGATE and manifest['file_count'] == len(manifest['files']) == 12,
        'Registered model identity differs')
    config = pinned_json(MODEL / 'config.json', CONFIG)
    index = pinned_json(MODEL / 'model.safetensors.index.json', INDEX)
    c = config['text_config']
    require(config['model_type'] == 'qwen3_5' and c['model_type'] == 'qwen3_5_text'
        and config['tie_word_embeddings'] is False and c['num_hidden_layers'] == 32
        and c['full_attention_interval'] == 4 and c['attn_output_gate'] is True
        and config['quantization'] == config['quantization_config'] == dict(bits=4, group_size=64, mode='affine'),
        'Fixed dense model/quantization geometry changed')
    require(c['layer_types'] == ['full_attention' if (i + 1) % 4 == 0 else 'linear_attention' for i in range(32)],
        'Layer phase contract differs')
    headers, header_ids = source_headers(manifest, index)
    expected = expected_shapes(c)
    require(len(expected) == 927 and {k for k in headers if k.startswith(PREFIX)} == set(expected), 'Canonical text coverage differs')
    excluded = {k: v for k, v in headers.items() if k not in expected}
    require(Counter(k.split('.')[0] for k in excluded) == Counter(vision_tower=333, mtp=31), 'Unexpected excluded namespace')
    full, active = [], [[], []]
    for name, (shape, dtype) in sorted(expected.items()):
        actual = headers[name]
        require(actual['shape'] == shape and actual['dtype'] == dtype, 'Independently derived tensor differs: ' + name)
        source_dtype, width = DTYPES[dtype]
        loaded_dtype = 'bfloat16' if source_dtype == 'float16' else source_dtype
        tensor = dict(sourceName=name, localName=name, shape=shape, sourceDType=source_dtype,
            loadedDType=loaded_dtype, byteCount=math.prod(shape) * width)
        full.append(tensor)
        match = LAYER.fullmatch(name)
        if match:
            global_layer = int(match[1]); stage = global_layer // 16
            local = PREFIX + f'model.layers.{global_layer % 16}.' + match[2]
        else:
            stage = 0 if name.startswith(PREFIX + 'model.embed_tokens.') else 1
            local = name
        active[stage].append(dict(tensor, localName=local))
    stages = []
    for i in range(2):
        active[i].sort(key=lambda x: x['localName'])
        placeholders = [('model.norm', [c['hidden_size']], 'parameter-only-replacement'),
            ('lm_head', [1, c['hidden_size']], 'module-replacement')] if i == 0 else [
            ('model.embed_tokens', [1, c['hidden_size']], 'module-replacement')]
        inert = [dict(path=PREFIX + path, replacementKind=kind, parameters=[dict(localName=PREFIX + path + '.weight',
            shape=shape, dtype='bfloat16', byteCount=math.prod(shape) * 2)]) for path, shape, kind in placeholders]
        inert_bytes = sum(p['byteCount'] for m in inert for p in m['parameters'])
        parameter_layout = active[i] + [dict(p, loadedDType=p['dtype']) for m in inert for p in m['parameters']]
        require(len({t['localName'] for t in parameter_layout}) == len(parameter_layout), 'Active/inert local name collision')
        stages.append(dict(stageIndex=i, sourceLayerStart=i * 16, sourceLayerEnd=(i + 1) * 16,
            activeTensorCount=len(active[i]), loadedTensorBytes=sum(x['byteCount'] for x in active[i]),
            largestHostTensorBytes=max(x['byteCount'] for x in active[i]), activeTensors=active[i],
            activeMappingSHA256=digest(canonical(active[i])), activeParameterLayoutSHA256=layout(active[i]),
            parameterLayoutSHA256=layout(parameter_layout), inertTensorBytes=inert_bytes, inertModules=inert))
    require([x['activeTensorCount'] for x in stages] == [463, 464]
        and [x['loadedTensorBytes'] for x in stages] == [2519016704, 2519024896]
        and [x['inertTensorBytes'] for x in stages] == [16384, 8192]
        and sum(x['byteCount'] for x in full) == 5038041600, 'Stage ownership/accounting differs')
    source_manifest = pinned_json(ARCHIVE / 'source-manifest.json', SOURCE_MANIFEST)
    source_by_name = {x['path']: x for x in source_manifest}
    selected = ['libs/mlx-swift-lm/Libraries/MLXLLM/Models/Qwen35.swift'] + [
        'experiments/cluster/inference/Sources/ClusterInference/' + n for n in [
            'CBv2OwnedStateSnapshot.swift', 'CBv2RequestGeometry.swift', 'VerifiedQwenLayerStageLoading.swift']]
    source_ids = []
    for path in selected:
        entry = source_by_name[path]
        require(digest((ARCHIVE / 'source' / path).read_bytes()) == entry['sha256'], 'Frozen policy source changed')
        source_ids.append(entry)
    return dict(schemaVersion=1, kind='qwen_layer_stage_real9b_expected', cpuOnly=True,
        helperSHA256=digest(Path(__file__).read_bytes()), modelDirectory=str(MODEL),
        artifactAggregateSHA256ClaimedByPinnedManifest=AGGREGATE, manifestSHA256=MANIFEST,
        configurationSHA256=CONFIG, indexSHA256=INDEX, headerIdentities=header_ids,
        safetensorBytesRead=sum(8 + x[0] for x in HEADERS.values()), weightPayloadBytesRead=0,
        fullArtifactHashesRechecked=False, registeredArtifactVerificationRequiredAtNativeRun=True,
        sourcePolicyArchive=str(ARCHIVE), sourcePolicyManifestSHA256=SOURCE_MANIFEST, sourcePolicyFiles=source_ids,
        loadedDTypePolicy=dict(bf16ConversionEnabled=True, rule='Only stored float16 is cast to bfloat16; float32, bfloat16 and uint32 remain unchanged.',
            storedFloat16CanonicalTensorCount=0, convertedCanonicalTensorCount=0, retainedFloat32ALogTensorCount=24),
        sourceHeaderTensorCount=len(headers), canonicalTensorCount=len(full), sourceModelTensorBytes=5038041600,
        sourceParameterLayoutSHA256=layout(full), largestSourceTensorBytes=max(x['byteCount'] for x in full),
        canonicalLoadedDTypeCounts=dict(Counter(x['loadedDType'] for x in full)),
        excluded=dict(count=len(excluded), namespaceCounts=dict(Counter(k.split('.')[0] for k in excluded)),
            names=sorted(excluded), reason='Canonical text-only model excludes vision_tower.* and mtp.*.'),
        fullCanonicalTensors=full, stages=stages, stateFrames=state_frames(c),
        stateContract=dict(batchSize=1, fullLocalLayerIndexIsGlobalLayerIndex=True,
            stageLocalLayerIndexRule='globalLayerIndex modulo 16', recurrentLayers=24, attentionLayers=8,
            fullBytesFormula='51511328 + 32768 * committedTokens', entriesDescribeCommittedLogicalStateOnly=True,
            includesAllocatorCapacityOrTransientGraphs=False),
        limitations=['Header identities and declared file sizes are verified, but weight payload values/full-file hashes are not read.',
            'This is an independent expected metadata/state geometry oracle, not evidence of native loading, forwarding, byte parity or performance.'])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, default=OUTPUT)
    output = parser.parse_args().output.resolve()
    require(output.is_relative_to(ROOT) and not output.is_relative_to(MODEL), 'Output must be in outtree research directory')
    result = derive()
    data = (json.dumps(result, indent=2, sort_keys=True, ensure_ascii=False, allow_nan=False) + '\n').encode()
    if output.exists():
        require(output.read_bytes() == data, 'Preserve differing existing oracle output')
    else:
        with output.open('xb') as stream:
            stream.write(data)
    print(json.dumps(dict(status='derived_and_verified', output=str(output), outputSHA256=digest(data),
        helperSHA256=result['helperSHA256'], canonicalTensorCount=927, stageTensorCounts=[463, 464],
        stageLoadedBytes=[s['loadedTensorBytes'] for s in result['stages']],
        headerBytesRead=result['safetensorBytesRead'], weightPayloadBytesRead=0), sort_keys=True))


if __name__ == '__main__':
    main()
