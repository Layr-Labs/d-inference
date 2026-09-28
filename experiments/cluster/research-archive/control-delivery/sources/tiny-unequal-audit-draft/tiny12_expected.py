"""Finite source-derived tiny12 metadata. No arrays, model files or runtime imports."""
import copy
import hashlib
import json
import math

PREFIX = 'language_model.'
RANGES = ((0, 4), (4, 12))
FRONTIERS = (32, 64, 65, 66, 67, 68)
WIDTH = {'bfloat16': 2, 'float16': 2, 'float32': 4, 'uint32': 4, 'int32': 4}


def require(value, message):
    if not value:
        raise ValueError(message)


def sha(raw):
    return hashlib.sha256(raw).hexdigest()


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'), allow_nan=False).encode()


def equal(left, right, message):
    require(canonical(left) == canonical(right), message)


def configuration():
    # SyntheticConfiguration.swift + the explicit wrapped tiny12 fixture.
    text = dict(model_type='qwen3_5_text', hidden_size=128, num_hidden_layers=12, intermediate_size=256,
        num_attention_heads=4, num_key_value_heads=2, head_dim=64,
        linear_num_key_heads=2, linear_num_value_heads=2, linear_key_head_dim=128, linear_value_head_dim=128,
        linear_conv_kernel_dim=4, full_attention_interval=4, vocab_size=512, tie_word_embeddings=False,
        max_position_embeddings=8192, mtp_num_hidden_layers=0, cluster_fixture_dtype='bfloat16',
        cluster_fixture_profile='tiny-layer-stage-12x4',
        layer_types=['full_attention' if (i + 1) % 4 == 0 else 'linear_attention' for i in range(12)])
    return dict(model_type='qwen3_5', text_config=text,
                quantization=dict(bits=4, group_size=64, mode='affine'))


def inert(index):
    paths = [('model.norm', [128], 'parameter-only-replacement',
              'Replace before parameter evaluation; stage 0 exports pre-final-norm hidden'),
             ('lm_head', [1, 128], 'module-replacement',
              'Replace before parameter evaluation; stage 0 discards lazy logits')] if index == 0 else [
             ('model.embed_tokens', [1, 128], 'module-replacement',
              'Replace before parameter evaluation; incoming residual bypasses embedding; preserve checkpoint activation dtype')]
    return [dict(path=PREFIX + path, replacementKind=kind, responsibility=reason,
        parameters=[dict(localName=PREFIX + path + '.weight', shape=shape, dtype='bfloat16',
                         byteCount=math.prod(shape) * 2)]) for path, shape, kind, reason in paths]


def plan():
    original = configuration()
    source_hash = sha(canonical(original))
    stages = []
    for index, (start, end) in enumerate(RANGES):
        construction = copy.deepcopy(original)
        text = construction['text_config']
        text['num_hidden_layers'] = end - start
        text['layer_types'] = original['text_config']['layer_types'][start:end]
        for item in inert(index):
            construction['quantization'][item['path']] = False
        roots = ([PREFIX + 'model.embed_tokens'] if index == 0 else [PREFIX + 'model.norm', PREFIX + 'lm_head'])
        roots += [PREFIX + 'model.layers.' + str(i) for i in range(end - start)]
        responsibilities = [{key: item[key] for key in ('path', 'responsibility')} for item in inert(index)]
        # This exact finite key order is Foundation JSONSerialization.sortedKeys
        # order, including its mixed-case activeModuleRoots/activeMTP ordering.
        # All nested keys here are lowercase ASCII, and all numbers are integers.
        identity = dict(activeModuleRoots=sorted(roots), activeMTP=False,
            adapter='qwen35-dense-layer-stage-v1', constructionConfigurationSHA256=sha(canonical(construction)),
            excludedSourceComponents=['vision', 'mtp'], inertModules=responsibilities,
            sourceConfigurationSHA256=source_hash, sourceLayerEnd=end, sourceLayerStart=start, stage=index)
        raw = json.dumps(identity, separators=(',', ':'), allow_nan=False).encode()
        stages.append(dict(stageIndex=index, sourceLayerStart=start, sourceLayerEnd=end,
            constructionConfiguration=construction, constructionConfigurationSHA256=sha(canonical(construction)),
            stagePlanSHA256=sha(raw)))
    fingerprint = sha(canonical(dict(adapter='qwen35-dense-two-layer-stages-v1',
        sourceConfigurationSHA256=source_hash, stages=[x['stagePlanSHA256'] for x in stages])))
    return dict(configuration=original, sourceConfigurationSHA256=source_hash, planSHA256=fingerprint, stages=stages)


def full_inventory():
    """Qwen35 constructor shapes; W4/G64 triplets; saved layer metadata F16."""
    tensors = []

    def add(name, shape, dtype='bfloat16'):
        name = PREFIX + name
        tensors.append(dict(sourceName=name, localName=name, shape=shape, sourceDType=dtype,
            loadedDType='bfloat16' if dtype == 'float16' else dtype, byteCount=math.prod(shape) * WIDTH[dtype]))

    def quantized(path, output, width):
        add(path + '.weight', [output, width // 8], 'uint32')
        metadata_dtype = 'float16' if '.layers.' in path else 'bfloat16'
        for suffix in ('scales', 'biases'):
            add(path + '.' + suffix, [output, width // 64], metadata_dtype)

    quantized('model.embed_tokens', 512, 128)
    quantized('lm_head', 512, 128)
    add('model.norm.weight', [128])
    for layer in range(12):
        prefix = 'model.layers.' + str(layer) + '.'
        for name in ('input_layernorm', 'post_attention_layernorm'):
            add(prefix + name + '.weight', [128])
        for name, output, width in [('gate_proj', 256, 128), ('up_proj', 256, 128), ('down_proj', 128, 256)]:
            quantized(prefix + 'mlp.' + name, output, width)
        if (layer + 1) % 4 == 0:
            for name, output, width in [('q_proj', 512, 128), ('k_proj', 128, 128),
                                        ('v_proj', 128, 128), ('o_proj', 128, 256)]:
                quantized(prefix + 'self_attn.' + name, output, width)
            for name in ('q_norm', 'k_norm'):
                add(prefix + 'self_attn.' + name + '.weight', [64])
        else:
            for name, output, width in [('in_proj_qkv', 768, 128), ('in_proj_z', 256, 128),
                                        ('in_proj_b', 2, 128), ('in_proj_a', 2, 128), ('out_proj', 128, 256)]:
                quantized(prefix + 'linear_attn.' + name, output, width)
            add(prefix + 'linear_attn.conv1d.weight', [768, 4, 1])
            for name in ('A_log', 'dt_bias'):
                add(prefix + 'linear_attn.' + name, [2])
            add(prefix + 'linear_attn.norm.weight', [128])
    tensors.sort(key=lambda x: x['sourceName'])
    require(len(tensors) == 352 and sum(x['sourceDType'] == 'float16' for x in tensors) == 186,
            'Source-derived tiny12 inventory counts differ')
    return tensors


def layout(tensors):
    return sha('\n'.join(sorted("%s:%s:%s" % (x['localName'], x['loadedDType'], x['shape'])
                               for x in tensors)).encode())


def expected():
    value = plan()
    full = full_inventory()
    value.update(fullCanonicalTensors=full, sourceModelTensorBytes=sum(x['byteCount'] for x in full),
                 sourceParameterLayoutSHA256=layout(full), canonicalTensorCount=352, fp16MetadataTensorCount=186)
    for index, (start, end) in enumerate(RANGES):
        entries = []
        for tensor in full:
            name = tensor['sourceName']
            if name.startswith(PREFIX + 'model.layers.'):
                parts = name.split('.')
                layer = int(parts[3])
                if not start <= layer < end:
                    continue
                parts[3] = str(layer - start)
                local = '.'.join(parts)
            else:
                owner = 0 if name.startswith(PREFIX + 'model.embed_tokens.') else 1
                if owner != index:
                    continue
                local = name
            entries.append(dict(tensor, localName=local))
        entries.sort(key=lambda x: x['localName'])
        require(len(entries) == (118, 234)[index], 'Stage source count differs')
        inactive = inert(index)
        parameters = [dict(p, loadedDType=p['dtype']) for item in inactive for p in item['parameters']]
        value['stages'][index].update(activeTensors=entries, inertModules=inactive,
            activeMappingSHA256=sha(canonical(entries)), activeParameterLayoutSHA256=layout(entries),
            parameterLayoutSHA256=layout(entries + parameters), loadedTensorBytes=sum(x['byteCount'] for x in entries),
            largestHostTensorBytes=max(x['byteCount'] for x in entries), inertTensorBytes=sum(x['byteCount'] for x in parameters))
    return value
