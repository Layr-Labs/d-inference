"""Registered9B metadata derivation for one explicit 12+20 short comparison.

Reads retained JSON/source metadata only. Never opens a model tensor payload.
Exact construction JSON comes from the prospectively pinned Foundation Plan
control; this module does not guess Foundation floating-point spellings.
"""
import copy
import hashlib
import json
import math
import re

BASIS_SHA256 = 'da869c797a5f37c264e4f1e1ddcf5c5f021630a9aae672dc2d2fb55ecd967a99'
CONFIG_SHA256 = 'c8e767de4953e58352fbc1acbf6615329075ed02fe16a36b8065714d85ee4423'
ARTIFACT_SHA256 = '127de76b4ef82b7aaa0acaac0ee31c784cff066eda64291f521f051469b7c24b'
PLAN_CONTROL_SHA256 = 'e6e062466026e921502e85159cdce293bbd6570cb4c6de6c6b4026c6bf006b89'
RANGES = [(0, 12), (12, 32)]
PREFIX = 'language_model.'
LAYER = re.compile(r'language_model\.model\.layers\.(\d+)\.(.+)')
WIDTH = {'float32': 4, 'bfloat16': 2, 'float16': 2, 'uint32': 4, 'int32': 4}


def require(value, message):
    if not value:
        raise ValueError(message)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=False, allow_nan=False).encode()


def parse(data):
    def unique(pairs):
        value = {}
        for key, item in pairs:
            require(key not in value, 'Duplicate JSON key')
            value[key] = item
        return value
    def floating(text):
        value = float(text)
        require(math.isfinite(value), 'Nonfinite JSON number')
        return value
    return json.loads(data, object_pairs_hook=unique, parse_float=floating,
        parse_constant=lambda _: require(False, 'Nonfinite JSON constant'),
        parse_int=lambda value: -0.0 if value == '-0' else int(value))


def layout(entries):
    return digest('\n'.join(sorted(f"{x['localName']}:{x['loadedDType']}:{x['shape']}" for x in entries)).encode())


def same(actual, expected, message):
    require(canonical(actual) == canonical(expected), message)


def semantic_equal(left, right):
    if type(left) is dict and type(right) is dict:
        return set(left) == set(right) and all(semantic_equal(left[key], right[key]) for key in left)
    if type(left) is list and type(right) is list:
        return len(left) == len(right) and all(semantic_equal(a, b) for a, b in zip(left, right))
    if type(left) in (int, float) and type(right) in (int, float):
        return math.isfinite(left) and math.isfinite(right) and left == right
    return type(left) is type(right) and left == right


def stage_identity_bytes(identity):
    # Explicit finite schema order validated by both independently pinned
    # Foundation control hashes. This is not a generic Foundation serializer:
    # its mixed-case activeModuleRoots/activeMTP ordering differs from Python.
    keys = ['activeModuleRoots', 'activeMTP', 'adapter', 'constructionConfigurationSHA256',
        'excludedSourceComponents', 'inertModules', 'sourceConfigurationSHA256',
        'sourceLayerEnd', 'sourceLayerStart', 'stage']
    require(set(identity) == set(keys), 'Stage identity fields differ')
    return json.dumps({key: identity[key] for key in keys}, separators=(',', ':'),
                      ensure_ascii=False, allow_nan=False).encode()


def construction_object(original, index):
    """Narrow source-derived transform for the pinned wrapped W4/G64 artifact."""
    result = copy.deepcopy(original)
    text = result['text_config']
    start, end = RANGES[index]
    text['num_hidden_layers'] = end - start
    text['mtp_num_hidden_layers'] = 0
    text['layer_types'] = ['full_attention' if (layer + 1) % 4 == 0 else 'linear_attention'
                           for layer in range(start, end)]
    if isinstance(result.get('mtplx_mtp'), dict):
        result['mtplx_mtp']['included'] = False
    defaults = {'bits': 4, 'group_size': 64, 'mode': 'affine'}
    # Exact registered policy has only defaults; no guessing arbitrary override
    # semantics. A changed source policy is a new qualification task.
    for key in ('quantization', 'quantization_config'):
        same(original[key], defaults, 'Pinned source quantization policy differs')
        result[key] = dict(defaults)
        for path in (['model.norm', 'lm_head'] if index == 0 else ['model.embed_tokens']):
            result[key][PREFIX + path] = False
    return result


def check_plan_control(control, configuration):
    require(set(control) == {'kind', 'cpuMetadataOnly', 'nativeModelExecution',
            'sourceConfigurationSHA256', 'planSHA256', 'layers', 'interval', 'stages'},
            'Plan control fields differ')
    require(control['kind'] == 'qwen_stage_cut_plan_control' and control['cpuMetadataOnly'] is True
            and control['nativeModelExecution'] is False, 'Plan control scope differs')
    require(control['sourceConfigurationSHA256'] == CONFIG_SHA256
            and type(control['layers']) is int and control['layers'] == 32
            and type(control['interval']) is int and control['interval'] == 4
            and isinstance(control['stages'], list) and len(control['stages']) == 2, 'Plan control source/geometry differs')
    original = parse(configuration)
    stages = []
    for index, actual in enumerate(control['stages']):
        require(set(actual) == {'index', 'sourceLayerStart', 'sourceLayerEnd', 'layers', 'fingerprint',
            'constructionConfigurationSHA256', 'constructionConfigurationUTF8', 'activeModuleRoots',
            'inertModules', 'quantizationMappings', 'excludedQuantizationPaths'}, 'Stage control fields differ')
        start, end = RANGES[index]
        require(all(type(actual[key]) is int for key in ('index', 'sourceLayerStart', 'sourceLayerEnd'))
                and (actual['index'], actual['sourceLayerStart'], actual['sourceLayerEnd']) == (index, start, end),
                'Stage control range differs')
        layer_map = [dict(globalIndex=layer, localIndex=layer-start,
            kind='full_attention' if (layer+1) % 4 == 0 else 'linear_attention') for layer in range(start, end)]
        same(actual['layers'], layer_map, 'Stage control layer map differs')
        require(type(actual['constructionConfigurationUTF8']) is str, 'Construction bytes must be exact UTF8 string')
        raw = actual['constructionConfigurationUTF8'].encode()
        require(0 < len(raw) <= 1048576 and digest(raw) == actual['constructionConfigurationSHA256'],
                'Construction bytes hash differs')
        # JSON numeric equality here deliberately avoids claiming a Python
        # recreation of Foundation spelling; the raw control bytes are pinned.
        require(semantic_equal(parse(raw), construction_object(original, index)), 'Construction semantics differ')
        roots = ([PREFIX+'model.embed_tokens'] if index == 0 else [PREFIX+'model.norm', PREFIX+'lm_head'])
        roots += [PREFIX+f'model.layers.{local}' for local in range(end-start)]
        inert = [dict(path=PREFIX+'model.norm', responsibility='Replace before parameter evaluation; stage 0 exports pre-final-norm hidden'),
            dict(path=PREFIX+'lm_head', responsibility='Replace before parameter evaluation; stage 0 discards lazy logits')] if index == 0 else [
            dict(path=PREFIX+'model.embed_tokens', responsibility='Replace before parameter evaluation; incoming residual bypasses embedding; preserve checkpoint activation dtype')]
        same(actual['activeModuleRoots'], sorted(roots), 'Stage active roots differ')
        same(actual['inertModules'], inert, 'Stage inert responsibilities differ')
        same(actual['quantizationMappings'], [], 'Unexpected override mapping')
        same(actual['excludedQuantizationPaths'], [], 'Unexpected excluded override')
        identity = dict(adapter='qwen35-dense-layer-stage-v1', sourceConfigurationSHA256=CONFIG_SHA256,
            stage=index, sourceLayerStart=start, sourceLayerEnd=end,
            constructionConfigurationSHA256=digest(raw), activeModuleRoots=sorted(roots), inertModules=inert,
            excludedSourceComponents=['vision', 'mtp'], activeMTP=False)
        require(digest(stage_identity_bytes(identity)) == actual['fingerprint'], 'Stage plan fingerprint differs')
        stages.append(dict(stageIndex=index, sourceLayerStart=start, sourceLayerEnd=end,
            constructionConfigurationSHA256=digest(raw), stagePlanSHA256=actual['fingerprint']))
    identity = dict(adapter='qwen35-dense-two-layer-stages-v1', sourceConfigurationSHA256=CONFIG_SHA256,
                    stages=[stage['stagePlanSHA256'] for stage in stages])
    require(digest(canonical(identity)) == control['planSHA256'], 'Full plan fingerprint differs')
    return stages


def derive(basis_bytes, configuration, plan_bytes):
    require(len(basis_bytes) <= 2*1024**2 and digest(basis_bytes) == BASIS_SHA256, 'Retained inventory pin differs')
    require(len(configuration) <= 1048576 and digest(configuration) == CONFIG_SHA256, 'Raw configuration pin differs')
    require(0 < len(plan_bytes) <= 1048576 and digest(plan_bytes) == PLAN_CONTROL_SHA256,
            'Exact prospective Plan control pin differs')
    basis, control = parse(basis_bytes), parse(plan_bytes)
    controls = check_plan_control(control, configuration)
    require(basis['canonicalTensorCount'] == 927 and basis['sourceHeaderTensorCount'] == 1291
        and basis['excluded']['count'] == 364 and basis['sourceModelTensorBytes'] == 5038041600
        and basis['artifactAggregateSHA256ClaimedByPinnedManifest'] == ARTIFACT_SHA256, 'Retained source differs')
    result = copy.deepcopy(basis)
    result.update(kind='qwen_layer_stage_real9b_cut12_expected', explicitStageCut=12,
        retainedInventorySHA256=BASIS_SHA256, planControlSHA256=digest(plan_bytes),
        planSHA256=control['planSHA256'], stateOwnership='global<12 belongs to stage0; global>=12 to stage1')
    result['retainedInventoryHelperSHA256'] = result.pop('helperSHA256')
    result['retainedInventorySafetensorBytesRead'] = result['safetensorBytesRead']
    result['safetensorBytesRead'] = 0
    result['stateContract']['stageLocalLayerIndexRule'] = 'globalLayerIndex minus explicit stage start (0 or 12)'
    result['limitations'] = [
        'Header identities and declared file sizes come from the pinned retained metadata oracle; this derivation reads no safetensor bytes.',
        'Exact construction JSON is bound to the prospective Foundation control; finite-schema plan identity hashes and parsed transformations are replayed independently.',
        'This is expected metadata/state geometry, not native loading, forwarding, paired-byte parity or performance evidence.']
    stages = []
    for index, (start, end) in enumerate(RANGES):
        entries = []
        for source in basis['fullCanonicalTensors']:
            match = LAYER.fullmatch(source['sourceName'])
            if match:
                layer = int(match[1])
                if not start <= layer < end:
                    continue
                local = PREFIX + f'model.layers.{layer-start}.' + match[2]
            else:
                name = source['sourceName']
                owner = 0 if name.startswith(PREFIX+'model.embed_tokens.') else 1
                if owner != index:
                    continue
                local = name
            entries.append(dict(source, localName=local))
        entries.sort(key=lambda x: x['localName'])
        require(len(entries) == [348, 579][index], 'Derived cut tensor counts differ')
        inert = copy.deepcopy(basis['stages'][index]['inertModules'])
        inert_parameters = [dict(p, loadedDType=p['dtype']) for item in inert for p in item['parameters']]
        value = dict(controls[index], activeTensorCount=len(entries), activeTensors=entries, inertModules=inert,
            activeMappingSHA256=digest(canonical(entries)), activeParameterLayoutSHA256=layout(entries),
            parameterLayoutSHA256=layout(entries+inert_parameters), loadedTensorBytes=sum(t['byteCount'] for t in entries),
            largestHostTensorBytes=max(t['byteCount'] for t in entries), inertTensorBytes=sum(p['byteCount'] for p in inert_parameters))
        require(value['loadedTensorBytes'] == [2032294848,3005746752][index]
                and value['inertTensorBytes'] == [16384,8192][index], 'Derived cut storage differs')
        stages.append(value)
    result['stages'] = stages
    for frame in result['stateFrames']:
        for entry in frame['entries']:
            layer = entry['globalLayerIndex']
            entry['stageIndex'] = 0 if layer < 12 else 1
            entry['localLayerIndex'] = layer if layer < 12 else layer-12
        frame['stageEntryCounts'] = [sum(x['stageIndex'] == i for x in frame['entries']) for i in range(2)]
        frame['stageStateBytes'] = [sum(x['byteCount'] for x in frame['entries'] if x['stageIndex'] == i) for i in range(2)]
        require(frame['stageEntryCounts'] == [27,45] and sum(frame['stageStateBytes']) == frame['fullStateBytes'],
                'Derived state ownership/conservation differs')
    return result
