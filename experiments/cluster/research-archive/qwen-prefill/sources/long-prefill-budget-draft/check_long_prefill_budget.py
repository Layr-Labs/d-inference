#!/usr/bin/env python3
"""CPU-only independent tensor arithmetic and source-contract audit.

Reads the pinned retained config and source text, never safetensor payloads.
Does not invoke Swift, MLX, a native inference binary, a build or a subprocess.
"""
from __future__ import annotations

import hashlib
import io
import json
from pathlib import Path
import unittest

ROOT = Path('/Users/developer/DarkbloomDev')
RESEARCH = ROOT / 'cluster-research'
REPO = ROOT / 'd-inference'
DRAFT = RESEARCH / 'long-prefill-budget-draft'
CONFIG = RESEARCH / 'runs/qwen-layer-stage-prefill-ranks-serial-peer24-20260914/remote-metadata/before-config.json'
EXPECTED = RESEARCH / 'qwen-layer-stage-real9b-expected-20260913.json'
CONFIG_SHA = 'c8e767de4953e58352fbc1acbf6615329075ed02fe16a36b8065714d85ee4423'
EXPECTED_SHA = 'da869c797a5f37c264e4f1e1ddcf5c5f021630a9aae672dc2d2fb55ecd967a99'
ARTIFACT = '127de76b4ef82b7aaa0acaac0ee31c784cff066eda64291f521f051469b7c24b'
INT_MAX = (1 << 63) - 1
REQUIRED_ENV = {'DARKBLOOM_CBV2_ATTN_QUERY_BLOCK': '128',
                'DARKBLOOM_BF16_WEIGHTS': '1', 'MLX_ENABLE_TF32': '1'}
ABSENT_ENV = ['MLX_METAL_GPU_ARCH', 'MLX_SDPA_BLOCKS']
SWIFT_FILES = ['QwenLongPrefillTensorBudget.swift', 'QwenRegistered9BLongPrefillAdmission.swift',
               'QwenLongPrefillArithmeticEnvironment.swift', 'QwenLongPrefillBudgetCheck.swift']
SOURCES = [
 'experiments/cluster/inference/Sources/ClusterInference/QwenLayerStageComparisonAdmission.swift',
 'experiments/cluster/inference/Sources/ClusterInference/VerifiedQwenDiagnosticLoading.swift',
 'experiments/cluster/inference/Sources/ClusterInference/VerifiedQwenLayerStageLoading.swift',
 'experiments/cluster/inference/Sources/ClusterInference/CBv2RequestGeometry.swift',
 'experiments/cluster/inference/Sources/ClusterInference/CBv2OwnedRequestState.swift',
 'experiments/cluster/inference/Sources/ClusterInference/CBv2RequestSession.swift',
 'libs/mlx-swift-lm/Libraries/MLXLLM/Models/Qwen35.swift',
 'libs/mlx-swift-lm/Libraries/MLXLLM/Models/GatedDelta.swift',
 'libs/mlx-swift-lm/Libraries/MLXLMCommon/ContinuousBatchingV2/AttentionV1.swift',
 'libs/mlx-swift/Source/MLX/MLXFastKernel.swift',
 'libs/mlx-swift/Source/MLX/ConstantArrayCastCache.swift',
 'libs/mlx-swift/Source/Cmlx/mlx/mlx/utils.h',
 'libs/mlx-swift/Source/Cmlx/mlx/mlx/utils.cpp',
 'libs/mlx-swift/Source/Cmlx/mlx/mlx/compile.cpp',
 'libs/mlx-swift/Source/Cmlx/mlx/mlx/backend/metal/matmul.cpp',
 'libs/mlx-swift/Source/Cmlx/mlx/mlx/backend/metal/quantized.cpp',
 'libs/mlx-swift/Source/Cmlx/mlx/mlx/backend/metal/scaled_dot_product_attention.cpp',
 'libs/mlx-swift/Source/Cmlx/mlx/mlx/backend/metal/conv.cpp',
 'libs/mlx-swift/Source/Cmlx/mlx/mlx/backend/metal/device.cpp',
 'libs/mlx-swift/Source/Cmlx/mlx/mlx/backend/metal/allocator.cpp',
 'experiments/cluster/inference/Sources/ClusterInference/PreparedQwenLayerSource.swift',
 'libs/mlx-swift-lm/Libraries/MLXLMCommon/ContinuousBatchingV2/EngineLoopV2.swift',
 'libs/mlx-swift-lm/Libraries/MLXLMCommon/ContinuousBatchingV2/MTP/MTPContractsV2.swift',
]


def checked(value):
    if type(value) is not int or not 0 <= value <= INT_MAX:
        raise ValueError('not a nonnegative signed-64-bit integer')
    return value


def product(*values):
    result = 1
    for value in values:
        result = checked(result * checked(value))
    return result


def add(*values):
    result = 0
    for value in values:
        result = checked(result + checked(value))
    return result


def geometry(text):
    names = {
        'layers': ('num_hidden_layers', 1, 128), 'interval': ('full_attention_interval', 2, 128),
        'hidden': ('hidden_size', 1, 8192), 'query_heads': ('num_attention_heads', 1, 128),
        'kv_heads': ('num_key_value_heads', 1, 128), 'head': ('head_dim', 1, 512),
        'key_heads': ('linear_num_key_heads', 1, 128), 'value_heads': ('linear_num_value_heads', 1, 128),
        'key': ('linear_key_head_dim', 1, 512), 'value': ('linear_value_head_dim', 1, 512),
        'kernel': ('linear_conv_kernel_dim', 1, 16),
    }
    g = {}
    for dest, (source, low, high) in names.items():
        n = text[source]
        if type(n) is not int or not low <= n <= high:
            raise ValueError('invalid geometry ' + source)
        g[dest] = n
    if (g['layers'] % g['interval'] or g['query_heads'] % g['kv_heads'] or
            g['value_heads'] % g['key_heads'] or g['key'] % 32):
        raise ValueError('unaligned geometry')
    return g


def estimate(text, maximum_tokens, chunk):
    g = geometry(text)
    if (type(maximum_tokens) is not int or not 1 <= maximum_tokens <= 32768 or
            type(chunk) is not int or not 1 <= chunk <= 512 or chunk > maximum_tokens):
        raise ValueError('invalid request capacity/chunk')
    # Count explicit tensor shapes, then accumulate individual layers rather
    # than reuse the Swift aggregate expression. Activations conservatively F32.
    channels = add(product(2, g['key_heads'], g['key']), product(g['value_heads'], g['value']))
    conv = product(g['kernel'] - 1, channels, 4)
    ssm = product(g['value_heads'], g['value'], g['key'], 4)
    single_k = product(maximum_tokens, g['kv_heads'], g['head'], 4)
    boundary = product(1, chunk, g['hidden'], 4)
    recurrent = []
    attention = []
    for layer in range(g['layers']):
        if (layer + 1) % g['interval'] == 0:
            attention += [single_k, single_k, 4]
        else:
            recurrent += [conv, ssm] * 3
    snapshot = max(single_k, conv, ssm)
    terms = {'threeRecurrentGenerationsBytes': add(*recurrent),
             'allKVCapacityAndOffsetsBytes': add(*attention),
             'largestSingleHostStateComponentBytes': snapshot,
             'twoBoundaryArraysBytes': add(boundary, boundary)}
    return {'convolutionBytesPerLayer': conv, 'ssmBytesPerLayer': ssm,
            'kvCapacityBytesPerAttentionLayer': product(single_k, 2), 'boundaryBytes': boundary,
            **terms, 'conservativeStateAndBoundaryBytes': add(*terms.values())}


def admit_environment(env):
    if any(env.get(name) != value for name, value in REQUIRED_ENV.items()):
        raise ValueError('missing/noncanonical required arithmetic value')
    if any(name in env for name in ABSENT_ENV):
        raise ValueError('forbidden override')
    return {'requiredValues': REQUIRED_ENV.copy(), 'requiredAbsentNames': ABSENT_ENV[:]}


def registered(config, artifact=ARTIFACT, prompt=8192, chunk=512, output=1,
               batch=1, teacher=0, dtype='bfloat16', bf16=True):
    if (not 0 < len(config) <= 1048576 or hashlib.sha256(config).hexdigest() != CONFIG_SHA or
            artifact != ARTIFACT or type(bf16) is not bool or not bf16 or dtype != 'bfloat16'):
        raise ValueError('wrong registered source/policy')
    for actual, wanted in zip((prompt, chunk, output, batch, teacher), (8192, 512, 1, 1, 0)):
        if type(actual) is not int or actual != wanted:
            raise ValueError('wrong registered request')
    root = json.loads(config)
    if root['model_type'] != 'qwen3_5':
        raise ValueError('wrong wrapper')
    text = root['text_config']
    if text['vocab_size'] != 248320 or add(prompt, output) > min(text['max_position_embeddings'], 32768):
        raise ValueError('wrong native context/vocabulary')
    budget = estimate(text, add(prompt, output), chunk)
    if not 512 * 1024**2 < budget['conservativeStateAndBoundaryBytes'] == 745345056 <= 768 * 1024**2:
        raise ValueError('wrong registered named tensor estimate')
    return budget


def pin(path):
    data = path.read_bytes()
    return {'path': str(path), 'byteCount': len(data), 'sha256': hashlib.sha256(data).hexdigest()}


def native_named_geometry():
    """Shape arithmetic from frozen metadata; no arrays or candidate values."""
    expected = json.loads(EXPECTED.read_bytes())
    frame = expected['stateFrames'][0]
    byte_width = {'bfloat16': 2, 'float32': 4, 'int32': 4}
    state_bytes, stage_kv_capacity = [], [0, 0]
    for entry in frame['entries']:
        shape = entry['shape'][:]
        width = byte_width[entry['dtype']]
        if entry['component'] in ('kv.keys', 'kv.values'):
            shape[2] = 8193
            stage_kv_capacity[entry['stageIndex']] = add(stage_kv_capacity[entry['stageIndex']], product(*shape, width))
            shape[2] = 8192
        state_bytes.append(product(*shape, width))
    return {'evidence': 'shape arithmetic from pinned prior inventory only; no new native capture',
            'finalCommittedTokens': 8192, 'reservedMaximumTokens': 8193,
            'componentCount': len(state_bytes), 'fullCommittedLogicalStateBytes': add(*state_bytes),
            'perStageKVCapacityBytes': stage_kv_capacity,
            'nativeBF16BoundaryBytes': product(1, 512, TEXT['hidden_size'], 2),
            'sourceWeightsExcludedFromTensorBudgetBytes': expected['sourceModelTensorBytes']}


CONFIG_BYTES = CONFIG.read_bytes()
if hashlib.sha256(CONFIG_BYTES).hexdigest() != CONFIG_SHA:
    raise ValueError('retained configuration pin differs')
TEXT = json.loads(CONFIG_BYTES)['text_config']


class BudgetTests(unittest.TestCase):
    def test_native_geometry_from_independent_retained_state_metadata(self):
        result = native_named_geometry()
        self.assertEqual(result['fullCommittedLogicalStateBytes'], 319946784)
        self.assertEqual(result['perStageKVCapacityBytes'], [134234112, 134234112])
        self.assertEqual(result['nativeBF16BoundaryBytes'], 4194304)
        self.assertEqual(result['componentCount'], 72)
        self.assertEqual(result['sourceWeightsExcludedFromTensorBudgetBytes'], 5038041600)

    def test_real_terms_from_individual_layer_shapes(self):
        self.assertEqual(registered(CONFIG_BYTES), {
            'convolutionBytesPerLayer': 98304, 'ssmBytesPerLayer': 2097152,
            'kvCapacityBytesPerAttentionLayer': 67117056, 'boundaryBytes': 8388608,
            'threeRecurrentGenerationsBytes': 158072832, 'allKVCapacityAndOffsetsBytes': 536936480,
            'largestSingleHostStateComponentBytes': 33558528, 'twoBoundaryArraysBytes': 16777216,
            'conservativeStateAndBoundaryBytes': 745345056})

    def test_generic_is_not_registered_execution(self):
        self.assertGreater(estimate(TEXT, 32768, 512)['conservativeStateAndBoundaryBytes'], 768 * 1024**2)
        with self.assertRaises(ValueError): registered(CONFIG_BYTES, prompt=65)

    def test_zero_convolution_history(self):
        t = dict(TEXT, linear_conv_kernel_dim=1)
        self.assertEqual(estimate(t, 1, 1)['convolutionBytesPerLayer'], 0)

    def test_checked_boundaries(self):
        self.assertEqual(product(4, 0, 8192), 0)
        self.assertEqual(add(INT_MAX, 0), INT_MAX)
        for fn, args in [(product, [INT_MAX, 2]), (add, [INT_MAX, 1]), (product, [-1]),
                         (add, [-1]), (product, [True]), (add, [1.0])]:
            with self.subTest(fn=fn.__name__, args=args), self.assertRaises(ValueError): fn(*args)

    def test_geometry_types_limits_and_alignment(self):
        cases = [('num_hidden_layers', 31), ('num_hidden_layers', 0), ('full_attention_interval', 0),
                 ('hidden_size', 8193), ('head_dim', 513), ('num_attention_heads', 15),
                 ('num_key_value_heads', 0), ('linear_num_key_heads', 0),
                 ('linear_num_value_heads', 31), ('linear_key_head_dim', 127),
                 ('linear_value_head_dim', 0), ('linear_conv_kernel_dim', 0),
                 ('num_hidden_layers', True), ('num_hidden_layers', 32.0)]
        for key, value in cases:
            with self.subTest(key=key, value=value), self.assertRaises(ValueError):
                estimate(dict(TEXT, **{key: value}), 8193, 512)

    def test_token_and_chunk_bounds(self):
        for capacity, chunk in [(-1, 1), (0, 1), (32769, 1), (8193, 513), (1, 2),
                                (8193, 0), (True, 1), (8193, 512.0)]:
            with self.subTest(capacity=capacity, chunk=chunk), self.assertRaises(ValueError):
                estimate(TEXT, capacity, chunk)

    def test_registered_source_and_policy_rejection(self):
        for mutation in [{'config': b''}, {'config': CONFIG_BYTES+b' '}, {'config': b'0' * 1048577},
                         {'artifact': '0'*64}, {'prompt': 65}, {'prompt': 8192.0}, {'chunk': 32},
                         {'output': 2}, {'batch': 2}, {'teacher': 1}, {'dtype': 'float32'},
                         {'bf16': False}, {'bf16': 1}]:
            kwargs = {'config': CONFIG_BYTES, **mutation}
            with self.subTest(mutation=list(mutation)), self.assertRaises(ValueError): registered(**kwargs)

    def test_exact_environment(self):
        actual = admit_environment(REQUIRED_ENV)
        self.assertEqual(actual, admit_environment(dict(REQUIRED_ENV, UNRELATED_NONSECRET='ignored')))

    def test_environment_missing_and_number_spellings(self):
        for name in REQUIRED_ENV:
            missing = REQUIRED_ENV.copy(); del missing[name]
            with self.subTest(name=name, missing=True), self.assertRaises(ValueError): admit_environment(missing)
            for value in ('0', '1.0', '1e0', 'true', ' 1', '1 ', '', 1, True):
                with self.subTest(name=name, value=value), self.assertRaises(ValueError):
                    admit_environment(dict(REQUIRED_ENV, **{name: value}))

    def test_environment_override_even_empty(self):
        for name in ABSENT_ENV:
            for value in ('', '0', '1', '128', None):
                with self.subTest(name=name, value=value), self.assertRaises(ValueError):
                    admit_environment(dict(REQUIRED_ENV, **{name: value}))

    def test_registered_swift_pins_and_separate_ceiling(self):
        s = (DRAFT / SWIFT_FILES[1]).read_text()
        for fragment in [CONFIG_SHA, ARTIFACT, '745_345_056', '768 * 1024 * 1024',
                         'promptCount == 8192, chunkSize == 512, outputCount == 1',
                         'actualArtifactVerificationStillRequired = true', 'wholeProcessMemorySafetyEstablished = false']:
            self.assertIn(fragment, s)

    def test_legacy_gate_is_still_512MiB_and_small(self):
        s = (REPO / SOURCES[0]).read_text()
        for fragment in ['guard total <= 512 * 1024 * 1024', '(1...128).contains(options.promptCount)',
                         '(1...32).contains(options.chunkSize)', '(1...4).contains(options.decodeCount)']:
            self.assertIn(fragment, s)
        self.assertNotIn('QwenLongPrefill', s)

    def test_all_swift_drafts_are_non_mlx_sources(self):
        for name in SWIFT_FILES:
            s = (DRAFT / name).read_text()
            for forbidden in ('import MLX', 'import MLXLLM', 'import MLXLMCommon', 'MLXArray(',
                              'ProcessInfo.processInfo.environment', 'Process()', 'URLSession'):
                self.assertNotIn(forbidden, s, name)

    def test_source_attention_dispatch_and_numeric_warning(self):
        s = (REPO / SOURCES[8]).read_text()
        for fragment in ['"DARKBLOOM_CBV2_ATTN_QUERY_BLOCK"', 'else { return 128 }',
                         'queryBlockSize > 0 && L > queryBlockSize',
                         'Numerics: NOT bit-identical to the single-call path']:
            self.assertIn(fragment, s)
        self.assertEqual(list(range(0, 512, 128)), [0, 128, 256, 384])

    def test_source_environment_default_lexemes(self):
        s = (REPO / SOURCES[11]).read_text()
        for fragment in ['get_var("MLX_ENABLE_TF32", 1)', 'get_var("MLX_METAL_GPU_ARCH", "")']:
            self.assertIn(fragment, s)
        self.assertIn('return atoi(buff_str);', (REPO / SOURCES[12]).read_text())
        s = (REPO / SOURCES[1]).read_text()
        self.assertIn('["DARKBLOOM_BF16_WEIGHTS"] ?? "1") == "1"', s)
        self.assertIn('if convertBF16 && array.dtype == .float16 { array = array.asType(.bfloat16) }', s)

    def test_source_sdpa_blocks_and_composed_head256(self):
        s = (REPO / SOURCES[16]).read_text()
        for fragment in ['env::get_var("MLX_SDPA_BLOCKS", 0)', 'query_sequence_length >= 1024 && query_head_dim == 256',
                         'if (query_sequence_length > 8)', 'return query_head_dim == 192 || query_head_dim == 256;']:
            self.assertIn(fragment, s)

    def test_source_gdn_no_env_switch(self):
        s = (REPO / SOURCES[7]).read_text()
        for fragment in ['ProcessInfo', 'getenv(', 'environment[']:
            self.assertNotIn(fragment, s)
        for fragment in ['for (int t = 0; t < T; ++t)', '#pragma clang fp reassociate(off)',
                         '#pragma clang fp contract(off)', 'GatedDeltaKernelManager.shared.kernel != nil',
                         'let beta = sigmoid(b).asType(.float32)', 'state = state.asType(.float32)']:
            self.assertIn(fragment, s)

    def test_source_hardware_and_build_dispatch_still_required(self):
        s = (REPO / SOURCES[18]).read_text()
        for fragment in ['arch_ = env::metal_gpu_arch();', '#ifdef MLX_METAL_NO_NAX',
                         'macOS 26.2', "gen >= (arch == 'p' ? 18 : 17)"]:
            self.assertIn(fragment, s)

    def test_source_qwen_depthwise_conv_skips_unfold_and_winograd_knobs(self):
        s = (REPO / SOURCES[6]).read_text()
        self.assertIn('groups: convDim,', s)
        s = (REPO / SOURCES[17]).read_text()
        self.assertIn('(groups == C) && groups == O && wt_strides[0] == 1', s)
        self.assertIn('depthwise_conv_1D_gpu(s, d, in, wt, out);\n    return;', s)


def main():
    paths = [Path(__file__), CONFIG, EXPECTED] + [DRAFT / name for name in SWIFT_FILES] + [REPO / name for name in SOURCES]
    before = [pin(path) for path in paths]
    if pin(EXPECTED)['sha256'] != EXPECTED_SHA:
        raise ValueError('frozen independent source/state inventory pin differs')
    stream = io.StringIO()
    suite = unittest.defaultTestLoader.loadTestsFromTestCase(BudgetTests)
    result = unittest.TextTestRunner(stream=stream, verbosity=2).run(suite)
    after = [pin(path) for path in paths]
    if before != after:
        raise ValueError('a source or input changed during CPU audit')
    report = {'kind': 'qwen_long_prefill_budget_cpu_audit', 'schemaVersion': 1,
              'status': 'passed' if result.wasSuccessful() else 'failed',
              'exitCode': 0 if result.wasSuccessful() else 1,
              'testsPassed': result.testsRun - len(result.failures) - len(result.errors),
              'testMethodsRun': result.testsRun, 'subtestsRetainedInLog': True,
              'testLog': stream.getvalue(), 'inputsUnchanged': True, 'inputs': before,
              'registeredBudget': registered(CONFIG_BYTES),
              'sourceDerivedNativeGeometry': native_named_geometry(),
              'registeredCeilingBytes': 768 * 1024**2, 'legacyCeilingBytes': 512 * 1024**2,
              'arithmeticContract': admit_environment(REQUIRED_ENV),
              'checksAreIndependentPythonArithmeticAndSourceAssertions': True,
              'swiftCompilationOrExecutionPerformed': False, 'nativeOrGPUWorkPerformed': False,
              'modelPayloadReadsPerformed': False, 'actualArtifactAggregateVerifiedHere': False,
              'sourceBackendAndHardwareNumericalIdentityEstablished': False,
              'wholeProcessMemorySafetyEstablished': False}
    print(json.dumps(report, indent=2, sort_keys=True, allow_nan=False))
    raise SystemExit(report['exitCode'])


if __name__ == '__main__':
    main()
