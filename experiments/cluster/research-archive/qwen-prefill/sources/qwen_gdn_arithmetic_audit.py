"""CPU-only arithmetic-control oracle; no MLX, model execution, or kernel claims.

The unchanged input-projection oracle checks the native baseline.  This module
checks widening, cast-back, semantic ownership, and END padding separately, then
recomputes comparisons.  Source-byte verification is an additional explicit API;
hashes in a report alone do not establish that a matrix came from the model.
"""
import math
import struct

import qwen_gdn_input_audit as base

require = base.require
FLOAT_DTYPES = ('float32', 'float16', 'bfloat16')
METADATA_CONVERSION = 'original stored floating values widened to Float32'


def identity(data, shape, dtype):
    return dict(shape=shape, dtype=dtype, logicalBytesSHA256=base.digest(data))


def capture_identity(record):
    return {key: record[key] for key in ('shape', 'dtype', 'logicalBytesSHA256')}


def check_identity(record, shape, dtype):
    require(isinstance(record, dict) and set(record) == {'shape', 'dtype', 'logicalBytesSHA256'},
            'Malformed arithmetic tensor identity')
    require(record['shape'] == shape and all(type(x) is int and x > 0 for x in record['shape'])
            and record['dtype'] == dtype, 'Arithmetic tensor identity geometry/dtype differs')
    digest = record['logicalBytesSHA256']
    require(isinstance(digest, str) and len(digest) == 64
            and all(c in '0123456789abcdef' for c in digest), 'Malformed arithmetic tensor digest')


def cast_bytes(values, dtype):
    """IEEE finite F32 -> destination, using round-to-nearest-even for BF16.

    BF16 formula matches the pinned MLX types/bf16.h. F16 uses Python's IEEE
    binary16 encoder. A finite input whose cast overflows is outside this probe.
    Signed zero is preserved and compared by bytes, not numeric equality.
    """
    require(dtype in FLOAT_DTYPES, 'Unsupported arithmetic cast dtype')
    result = bytearray()
    for raw in values:
        value = base.f32(raw)
        if dtype == 'float32':
            result.extend(struct.pack('<f', value))
        elif dtype == 'float16':
            try:
                result.extend(struct.pack('<e', value))
            except OverflowError as exc:
                raise ValueError('Finite cast overflows float16') from exc
        else:
            bits = struct.unpack('<I', struct.pack('<f', value))[0]
            word = ((bits + 0x7fff + ((bits >> 16) & 1)) >> 16) & 0xffff
            require(word & 0x7f80 != 0x7f80, 'Finite cast overflows bfloat16')
            result.extend(struct.pack('<H', word))
    return bytes(result)


def decode_floats(data, dtype):
    require(dtype in FLOAT_DTYPES, 'Unsupported source floating dtype')
    width = 4 if dtype == 'float32' else 2
    require(len(data) % width == 0, 'Unaligned floating source bytes')
    if dtype == 'bfloat16':
        values = [struct.unpack('<f', struct.pack('<I', word << 16))[0]
                  for (word,) in struct.iter_unpack('<H', data)]
    else:
        values = [value for (value,) in struct.iter_unpack('<f' if width == 4 else '<e', data)]
    require(all(math.isfinite(value) for value in values), 'Nonfinite floating source bytes')
    return values


def widened_bytes(data, dtype):
    return base.logical_bytes(decode_floats(data, dtype), 'float32')


def _check_rank(record, rank):
    actual = record.get('rank')
    require(actual is None if rank is None else type(actual) is int and actual == rank,
            'Arithmetic rank identity/order differs')


def _check_layout(record, text, rank):
    _check_rank(record, rank)
    require(base.canonical(record['components']) == base.canonical(base.components(text, rank)),
            'Arithmetic component layout differs')
    expected = base.selections(text, rank)
    require(base.canonical(record['selections']) == base.canonical(expected)
            and record['selectionSHA256'] == base.digest(base.canonical(expected)),
            'Arithmetic selection differs')


def _capture(record, shape, dtype):
    values = base.capture(record)
    require(record['shape'] == shape and record['dtype'] == dtype,
            'Arithmetic capture geometry/dtype differs')
    return values


def _metric(left, right):
    return dict(base.metrics(left, right), float32LogicalBytesExact=(
        base.logical_bytes(left, 'float32') == base.logical_bytes(right, 'float32')))


def _selected(full, width, text, rank):
    result = []
    components = base.components(text, rank)
    for row in range(len(full) // width):
        for component in components:
            lo, hi = component['sourceRows']
            result.extend(full[row * width + lo:row * width + hi])
    return result


def _partition_comparison(full, ranks, text):
    """Compare full to semantically reassembled ranks, with component metrics."""
    width = base.components(text)[-1]['localRows'][1]
    require(len(full) % width == 0 and len(ranks) == 2, 'Arithmetic metric geometry differs')
    rows = len(full) // width
    reassembled = [None] * len(full)
    rank_reports = []
    for rank, values in enumerate(ranks):
        components = base.components(text, rank)
        rank_width = components[-1]['localRows'][1]
        require(len(values) == rows * rank_width, 'Arithmetic metric rank geometry differs')
        per = []
        for component in components:
            left = base.columns(full, width, component['sourceRows'])
            right = base.columns(values, rank_width, component['localRows'])
            per.append(dict(name=component['name'], aggregate=_metric(left, right)))
            lo, hi = component['sourceRows']
            a, b = component['localRows']
            for row in range(rows):
                require(all(value is None for value in reassembled[row * width + lo:row * width + hi]),
                        'Overlapping arithmetic component ownership')
                reassembled[row * width + lo:row * width + hi] = values[row * rank_width + a:row * rank_width + b]
        rank_reports.append(dict(rank=rank, components=per))
    require(all(value is not None for value in reassembled), 'Incomplete arithmetic component ownership')
    return dict(reassembled=_metric(full, reassembled), ranks=rank_reports)


def arithmetic_oracle(report, text):
    """Validate raw controls and return CPU metrics; also call source-byte API."""
    require(type(report.get('schemaVersion')) is int and report['schemaVersion'] == 1
            and report.get('kind') == 'qwen_gdn_arithmetic_check', 'Unsupported arithmetic report identity')
    require(report.get('correctnessOnly') is True and report.get('throughputMeasurementValid') is False,
            'Arithmetic diagnostic measurement scope differs')
    original = dict(report, kind='qwen_gdn_input_projection_check')
    original.pop('arithmeticVariants', None)
    baseline = base.projection_oracle(original, text)
    base.verify_native_differences(report['componentDifferences'], baseline)
    variants = report['arithmeticVariants']
    require(type(variants.get('schemaVersion')) is int and variants['schemaVersion'] == 1,
            'Unsupported arithmetic variants schema')
    fp32 = variants['float32']
    padded = variants['paddedNative']
    require(fp32.get('kind') == 'float32_projection' and fp32.get('metadataConversion') == METADATA_CONVERSION,
            'Float32 control policy differs')
    require(padded.get('kind') == 'end_zero_rows', 'Padding control policy differs')
    require(isinstance(fp32.get('evaluations'), list) and len(fp32['evaluations']) == 3,
            'Missing Float32 evaluations')
    require(isinstance(padded.get('evaluations'), list) and len(padded['evaluations']) == 2,
            'Missing padded evaluations')

    native_dtype = report['normalizedInput']['dtype']
    hidden = text['hidden_size']
    rows = report['chunkSize']
    full_width = base.components(text)[-1]['localRows'][1]
    expected_estimate = (4 * full_width * (hidden // 8 * 4 + 2 * (hidden // 64) * 4)
        + 16 * rows * full_width * 4 + 4 * rows * hidden * 4)
    require(type(variants.get('estimatedAdditionalTensorAndCaptureBytes')) is int
            and variants['estimatedAdditionalTensorAndCaptureBytes'] == expected_estimate
            and type(variants.get('estimatedAdditionalByteLimit')) is int
            and variants['estimatedAdditionalByteLimit'] == 512 * 1024 * 1024
            and expected_estimate <= variants['estimatedAdditionalByteLimit']
            and variants.get('estimateIsNotWholeProcessPeakBound') is True,
            'Arithmetic additional-memory estimate differs')
    normalized = base.capture(report['normalizedInput'])
    native_input_identity = capture_identity(report['normalizedInput'])
    wide_input_identity = identity(base.logical_bytes(normalized, 'float32'), [1, rows, hidden], 'float32')
    native_records = [report['full'], *report['ranks']]
    native_values = [base.capture(item['output']) for item in native_records]
    wide_values, cast_values, departures = [], [], []
    for rank, record, native, native_output in zip((None, 0, 1), fp32['evaluations'], native_records, native_values):
        _check_layout(record, text, rank)
        width = full_width if rank is None else full_width // 2
        check_identity(record['input'], [1, rows, hidden], 'float32')
        require(record['input'] == wide_input_identity, 'Float32 input widening differs')
        check_identity(record['fusedWeight'], [width, hidden // 8], 'uint32')
        require(record['fusedWeight'] == native['fusedWeight'], 'Float32 packed weight changed')
        for name in ('fusedScales', 'fusedBiases'):
            check_identity(record[name], [width, hidden // 64], 'float32')
            if native_dtype == 'float32':
                require(record[name] == native[name], 'Already-Float32 metadata changed')
        actual = _capture(record['output'], [1, rows, width], 'float32')
        cast = _capture(record['nativeCastOutput'], [1, rows, width], native_dtype)
        require(base.logical_bytes(cast, native_dtype) == cast_bytes(actual, native_dtype),
                'Float32 native cast bytes differ')
        wide_values.append(actual)
        cast_values.append(cast)
        reference = native_values[0] if rank is None else _selected(native_values[0], full_width, text, rank)
        departures.append(dict(rank=rank, versusNativeCorrespondingProjection=_metric(native_output, actual),
            nativeCastVersusNativeCorrespondingProjection=_metric(native_output, cast),
            versusSelectedNativeFull=_metric(reference, actual),
            nativeCastVersusSelectedNativeFull=_metric(reference, cast)))

    padded_values, padded_departures = [], []
    for rank, record in enumerate(padded['evaluations']):
        _check_layout(record, text, rank)
        real_rows = full_width // 2
        geometry = dict(realRows=real_rows, paddedRows=full_width, appendedZeroRows=full_width - real_rows)
        require(all(type(record.get(name)) is int and record[name] == value for name, value in geometry.items())
                and base.canonical(record.get('cropRows')) == base.canonical([0, real_rows]),
                'Padding/crop row geometry differs')
        require(record.get('zeroPaddingValidated') is True, 'Native zero-padding validation missing')
        check_identity(record['input'], [1, rows, hidden], native_dtype)
        require(record['input'] == native_input_identity, 'Padded input differs from native input')
        check_identity(record['fusedWeight'], [full_width, hidden // 8], 'uint32')
        for name in ('fusedScales', 'fusedBiases'):
            check_identity(record[name], [full_width, hidden // 64], native_dtype)
        actual = _capture(record['output'], [1, rows, real_rows], native_dtype)
        uncropped = _capture(record['paddedOutput'], [1, rows, full_width], native_dtype)
        crop = base.columns(uncropped, full_width, [0, real_rows])
        tail = base.columns(uncropped, full_width, [real_rows, full_width])
        require(base.logical_bytes(crop, native_dtype) == base.logical_bytes(actual, native_dtype),
                'Padded output crop bytes differ')
        require(all(value == 0 for value in tail), 'Padded output tail is not zero')
        padded_values.append(actual)
        reference = _selected(native_values[0], full_width, text, rank)
        padded_departures.append(dict(rank=rank, versusNativeRank=_metric(native_values[rank + 1], actual),
            versusSelectedNativeFull=_metric(reference, actual), paddedTailValuesChecked=len(tail),
            cropLogicalBytesExact=True, paddedTailNumericallyZero=True))

    return dict(schemaVersion=1, kind='qwen_gdn_arithmetic_cpu_oracle', baseline=baseline,
        float32=dict(fullVersusRanks=_partition_comparison(wide_values[0], wide_values[1:], text),
            nativeCastFullVersusRanks=_partition_comparison(cast_values[0], cast_values[1:], text),
            departures=departures, widenedInputBytesVerified=True, nativeCastBytesVerified=True),
        paddedNative=dict(nativeFullVersusRanks=_partition_comparison(native_values[0], padded_values, text),
            departures=padded_departures), componentLayoutIndependentlyDerived=True,
        sourceWeightBytesVerified=False, notACPUReimplementationOfMetalQuantizedMatmul=True,
        kernelDispatchNotTraced=True, throughputMeasurementValid=False)


def loaded_source_bytes(tensor, ranges, convert_bf16):
    """Read only selected rows, applying exactly the loader's F16->BF16 policy."""
    require(type(convert_bf16) is bool, 'Loader BF16 policy must be boolean')
    stored_dtype = tensor['dtype']
    require(stored_dtype in ('BF16', 'F16', 'F32', 'U32'), 'Unsupported source tensor dtype')
    width = 4 if stored_dtype in ('F32', 'U32') else 2
    shape = tensor['shape']
    require(isinstance(shape, list) and len(shape) in (1, 2)
            and all(type(n) is int and n > 0 for n in shape), 'Malformed source tensor shape')
    lo, hi = tensor['data_offsets']
    require(type(lo) is int and type(hi) is int and 0 <= lo < hi
            and hi - lo == math.prod(shape) * width, 'Source tensor byte span differs')
    row_bytes = math.prod(shape[1:]) * width
    require(hi - lo <= 128 * 1024 * 1024, 'Unbounded diagnostic source tensor')
    data = bytearray()
    selected_rows = 0
    with tensor['path'].open('rb') as handle:
        for a, b in ranges:
            require(type(a) is int and type(b) is int and 0 <= a < b <= shape[0], 'Invalid arithmetic source rows')
            handle.seek(tensor['base'] + lo + a * row_bytes)
            part = handle.read((b - a) * row_bytes)
            require(len(part) == (b - a) * row_bytes, 'Truncated arithmetic source tensor')
            data.extend(part)
            selected_rows += b - a
    dtype = dict(BF16='bfloat16', F16='float16', F32='float32', U32='uint32')[stored_dtype]
    if dtype == 'float16' and convert_bf16:
        data = cast_bytes(decode_floats(data, 'float16'), 'bfloat16')
        dtype = 'bfloat16'
    elif dtype != 'uint32':
        decode_floats(data, dtype)  # Reject nonfinite source metadata before widening.
    return bytes(data), dtype, [selected_rows, *shape[1:]]


def verify_real_arithmetic_weight_bytes(report, model, text):
    """Bind source/native/variant identities to actual safetensor row bytes.

    For BF16/F32 artifacts the old source-byte oracle also runs unchanged. F16
    source data is explicitly converted under the saved loader policy before any
    widening, never directly widened from F16 when BF16 conversion is enabled.
    This is a tensor-byte check; the caller owns whole-artifact aggregate pinning.
    """
    require(report.get('kind') == 'qwen_gdn_arithmetic_check', 'Not an arithmetic report')
    require(type(report.get('bf16ConversionEnabled')) is bool, 'Missing loader conversion policy')
    convert = report['bf16ConversionEnabled']
    tensors = base.checkpoint_headers(model)
    source = report['sourceProjections']
    native_dtype = report['normalizedInput']['dtype']
    prefix = 'language_model.model.layers.0.'
    require(report['inputNormPath'] == prefix + 'input_layernorm', 'Arithmetic source norm path differs')
    names = [item['name'] for item in base.selections(text)]
    require([item['name'] for item in source] == names, 'Arithmetic source projection order differs')
    source_keys = [report['inputNormPath'] + '.weight'] + [prefix + 'linear_attn.' + name + '.' + suffix
        for name in names for suffix in ('weight', 'scales', 'biases')]
    require(all(key in tensors for key in source_keys), 'Missing arithmetic source tensor')
    old_oracle = None
    if all(tensors[key]['dtype'] != 'F16' for key in source_keys):
        old_oracle = base.verify_real_weight_bytes(report, model, text)
    checks = []

    def check(actual, data, shape, dtype, label):
        expected = identity(data, shape, dtype)
        require(actual == expected, 'Actual source/variant bytes differ: ' + label)
        checks.append(dict(parameter=label, bytesChecked=len(data), **expected))

    norm = tensors[report['inputNormPath'] + '.weight']
    data, dtype, shape = loaded_source_bytes(norm, [[0, text['hidden_size']]], convert)
    check(report['inputNormWeight'], data, shape, dtype, 'inputNormWeight')
    require(dtype == native_dtype, 'Source norm dtype differs from native input')
    require(base.f32(report['inputNormEpsilon']) == base.f32(text['rms_norm_eps']), 'Source norm epsilon differs')
    for projection, choice in zip(source, base.selections(text)):
        require(projection['modulePath'] == prefix + 'linear_attn.' + projection['name'], 'Arithmetic source path differs')
        require(type(projection['bits']) is int and projection['bits'] == 4
                and type(projection['groupSize']) is int and projection['groupSize'] == 64
                and projection['mode'] == 'affine'
                and type(projection['inputWidth']) is int and projection['inputWidth'] == text['hidden_size']
                and type(projection['outputRows']) is int and projection['outputRows'] == choice['ranges'][0][1],
                'Arithmetic source quantization/geometry differs')
        for suffix in ('weight', 'scales', 'biases'):
            data, dtype, shape = loaded_source_bytes(tensors[projection['modulePath'] + '.' + suffix], choice['ranges'], convert)
            check(projection[suffix], data, shape, dtype, projection['name'] + '.' + suffix)

    variants = report['arithmeticVariants']
    for index, rank in enumerate((None, 0, 1)):
        native = [report['full'], *report['ranks']][index]
        _check_layout(native, text, rank)
        wide = variants['float32']['evaluations'][index]
        _check_layout(wide, text, rank)
        padded = None if rank is None else variants['paddedNative']['evaluations'][rank]
        if padded is not None:
            _check_layout(padded, text, rank)
        for suffix, field in (('weight', 'fusedWeight'), ('scales', 'fusedScales'), ('biases', 'fusedBiases')):
            data = bytearray()
            rows = 0
            cols = dtype = None
            for projection, choice in zip(source, base.selections(text, rank)):
                part, part_dtype, shape = loaded_source_bytes(tensors[projection['modulePath'] + '.' + suffix], choice['ranges'], convert)
                require(dtype is None or dtype == part_dtype, 'Mixed arithmetic source metadata dtypes')
                require(cols is None or cols == shape[1], 'Mixed arithmetic source columns')
                data.extend(part)
                rows += shape[0]
                cols, dtype = shape[1], part_dtype
            native_shape = [rows, cols]
            check(native[field], data, native_shape, dtype, f'native.rank{rank}.{suffix}')
            wide_data = bytes(data) if suffix == 'weight' else widened_bytes(data, dtype)
            wide_dtype = dtype if suffix == 'weight' else 'float32'
            check(wide[field], wide_data, native_shape, wide_dtype, f'float32.rank{rank}.{suffix}')
            if padded is not None:
                full_rows = base.components(text)[-1]['localRows'][1]
                zero_bytes = (full_rows - rows) * cols * (4 if dtype in ('uint32', 'float32') else 2)
                padded_data = bytes(data) + bytes(zero_bytes)
                check(padded[field], padded_data, [full_rows, cols], dtype, f'padded.rank{rank}.{suffix}')
    return dict(schemaVersion=1, sourceWeightBytesVerified=True, tensorChecks=checks,
        tensorCheckCount=len(checks), baselineByteOracleAlsoPassed=old_oracle is not None,
        baselineByteOracleTensorChecks=old_oracle,
        storedF16ConvertedBeforeFloat32Widening=convert,
        wholeArtifactPinNotRecomputedByThisHelper=True)
