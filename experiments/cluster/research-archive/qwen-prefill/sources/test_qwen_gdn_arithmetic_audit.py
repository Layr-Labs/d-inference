"""Bounded CPU fixtures testing arithmetic control integrity and byte provenance."""
import copy
import json
from pathlib import Path
import struct
import tempfile
import unittest

import qwen_gdn_input_audit as base
import qwen_gdn_arithmetic_audit as audit
from test_qwen_gdn_input_audit import TEXT, cap, fixture, write_checkpoint


def native_differences(oracle):
    result = []
    for rank in oracle['ranks']:
        for component in rank['components']:
            metric = component['aggregate']
            result.append(dict(rank=rank['rank'], component=component['name'],
                comparedValues=metric['comparedValues'], differingValues=metric['differingValues'],
                exactValues=metric['exact'], maximumAbsoluteError=metric['maximumAbsoluteError'],
                rootMeanSquareError=metric['rootMeanSquareError'], relativeRMSError=metric['relativeRMSError'],
                **({'bfloat16Steps': component['bfloat16Steps']} if 'bfloat16Steps' in component else {})))
    return result


def arithmetic_fixture(directory):
    record = fixture('bfloat16')
    path = write_checkpoint(Path(directory), record)
    record.update(schemaVersion=1, kind='qwen_gdn_arithmetic_check', correctnessOnly=True,
        throughputMeasurementValid=False, bf16ConversionEnabled=True)
    record['componentDifferences'] = native_differences(base.projection_oracle(record, TEXT))
    tensors = base.checkpoint_headers(directory)
    fp32, padded = [], []
    for rank, native in [(None, record['full']), *enumerate(record['ranks'])]:
        wide = copy.deepcopy(native)
        wide['input'] = audit.identity(base.logical_bytes(record['normalizedInput']['values'], 'float32'), [1, 2, 64], 'float32')
        # All source values are exact BF16; +2^-20 changes F32 while rounding
        # back to these values in BF16. Both independently selected ranks agree.
        values = [value + 2**-20 for value in native['output']['values']]
        wide['output'] = cap(native['output']['shape'], values, 'float32')
        wide['nativeCastOutput'] = copy.deepcopy(native['output'])
        pad = copy.deepcopy(native)
        if rank is not None:
            pad.update(input=audit.capture_identity(record['normalizedInput']), realRows=130,
                paddedRows=260, appendedZeroRows=130, zeroPaddingValidated=True, cropRows=[0, 130])
            original = native['output']['values']
            pad['paddedOutput'] = cap([1, 2, 260], original[:130] + [0.0] * 130 + original[130:] + [0.0] * 130, 'bfloat16')
        for suffix, field, cols, width in [('weight', 'fusedWeight', 8, 4), ('scales', 'fusedScales', 1, 2), ('biases', 'fusedBiases', 1, 2)]:
            raw = bytearray()
            for source, selection in zip(record['sourceProjections'], base.selections(TEXT, rank)):
                part, _, _ = base.selected_source_bytes(tensors[source['modulePath'] + '.' + suffix], selection['ranges'])
                raw.extend(part)
            if suffix != 'weight':
                expanded = b''.join(struct.pack('<I', word << 16) for (word,) in struct.iter_unpack('<H', raw))
                wide[field] = audit.identity(expanded, native[field]['shape'], 'float32')
            if rank is not None:
                pad[field] = audit.identity(bytes(raw) + bytes(130 * cols * width), [260, cols], native[field]['dtype'])
        fp32.append(wide)
        if rank is not None:
            padded.append(pad)
    record['arithmeticVariants'] = dict(schemaVersion=1,
        estimatedAdditionalTensorAndCaptureBytes=4 * 260 * (64 // 8 * 4 + 2 * (64 // 64) * 4)
            + 16 * 2 * 260 * 4 + 4 * 2 * 64 * 4,
        estimatedAdditionalByteLimit=512 * 1024 * 1024, estimateIsNotWholeProcessPeakBound=True,
        float32=dict(kind='float32_projection', metadataConversion=audit.METADATA_CONVERSION, evaluations=fp32),
        paddedNative=dict(kind='end_zero_rows', evaluations=padded))
    return record, path


def recode_checkpoint(path, stored_dtype):
    """Fixture-only metadata recode, keeping each finite numeric value exact."""
    original = path.read_bytes()
    length = struct.unpack('<Q', original[:8])[0]
    header = json.loads(original[8:8 + length])
    payload = bytearray()
    for tensor in header.values():
        lo, hi = tensor['data_offsets']
        data = original[8 + length + lo:8 + length + hi]
        if tensor['dtype'] == 'BF16':
            values = [struct.unpack('<f', struct.pack('<I', word << 16))[0]
                for (word,) in struct.iter_unpack('<H', data)]
            data = b''.join(struct.pack('<f' if stored_dtype == 'F32' else '<e', value) for value in values)
            tensor['dtype'] = stored_dtype
        tensor['data_offsets'] = [len(payload), len(payload) + len(data)]
        payload.extend(data)
    encoded = json.dumps(header, separators=(',', ':')).encode()
    path.write_bytes(struct.pack('<Q', len(encoded)) + encoded + payload)


class ArithmeticTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.record, self.path = arithmetic_fixture(self.temp.name)

    @property
    def wide(self):
        return self.record['arithmeticVariants']['float32']['evaluations']

    @property
    def padded(self):
        return self.record['arithmeticVariants']['paddedNative']['evaluations']

    def raw(self):
        return audit.arithmetic_oracle(self.record, TEXT)

    def source(self):
        return audit.verify_real_arithmetic_weight_bytes(self.record, self.temp.name, TEXT)

    def test_valid_controls_and_real_source_bindings(self):
        result = self.raw()
        self.assertTrue(result['float32']['fullVersusRanks']['reassembled']['exact'])
        self.assertTrue(result['float32']['nativeCastFullVersusRanks']['reassembled']['exact'])
        self.assertEqual(result['float32']['departures'][0]['versusNativeCorrespondingProjection']['differingValues'], 520)
        self.assertTrue(result['float32']['departures'][0]['nativeCastVersusNativeCorrespondingProjection']['exact'])
        self.assertTrue(result['paddedNative']['nativeFullVersusRanks']['reassembled']['exact'])
        result = self.source()
        self.assertEqual(result['tensorCheckCount'], 37)
        self.assertTrue(result['baselineByteOracleAlsoPassed'])

    def test_variant_metric_difference_is_localized(self):
        output = self.wide[1]['output']
        output['values'][0] += 2**-18
        output['logicalBytesSHA256'] = base.digest(base.logical_bytes(output['values'], 'float32'))
        result = self.raw()['float32']['fullVersusRanks']
        self.assertEqual(result['reassembled']['differingValues'], 1)
        self.assertEqual(result['ranks'][0]['components'][0]['aggregate']['differingValues'], 1)
        self.assertTrue(all(item['aggregate']['exact'] for item in result['ranks'][1]['components']))

    def test_corrupt_widened_input_hash_rejected(self):
        self.wide[1]['input']['logicalBytesSHA256'] = '0' * 64
        with self.assertRaisesRegex(ValueError, 'input widening'):
            self.raw()

    def test_boolean_identity_geometry_and_estimate_not_accepted_as_integers(self):
        self.wide[1]['input']['shape'][0] = True
        with self.assertRaisesRegex(ValueError, 'geometry/dtype'):
            self.raw()
        self.wide[1]['input']['shape'][0] = 1
        self.record['arithmeticVariants']['estimatedAdditionalTensorAndCaptureBytes'] += 1
        with self.assertRaisesRegex(ValueError, 'memory estimate'):
            self.raw()

    def test_packed_weight_change_and_metadata_dtype_rejected(self):
        self.wide[0]['fusedWeight']['logicalBytesSHA256'] = '0' * 64
        with self.assertRaisesRegex(ValueError, 'packed weight'):
            self.raw()
        self.wide[0]['fusedWeight'] = copy.deepcopy(self.record['full']['fusedWeight'])
        self.wide[0]['fusedScales']['dtype'] = 'bfloat16'
        with self.assertRaisesRegex(ValueError, 'geometry/dtype'):
            self.raw()

    def test_raw_output_hash_shape_and_cast_must_agree(self):
        self.wide[0]['output']['values'][0] = 4.0
        with self.assertRaisesRegex(ValueError, 'hash differs'):
            self.raw()
        self.wide[0]['output']['logicalBytesSHA256'] = base.digest(base.logical_bytes(self.wide[0]['output']['values'], 'float32'))
        with self.assertRaisesRegex(ValueError, 'cast bytes'):
            self.raw()
        self.wide[0]['nativeCastOutput']['shape'] = [1, 4, 130]
        with self.assertRaisesRegex(ValueError, 'geometry/dtype'):
            self.raw()

    def test_rank_order_boolean_and_semantic_ownership_rejected(self):
        self.wide[1]['rank'] = False
        with self.assertRaisesRegex(ValueError, 'rank identity'):
            self.raw()
        self.wide[1]['rank'] = 0
        self.wide[1]['components'][0]['sourceRows'] = [32, 64]
        with self.assertRaisesRegex(ValueError, 'component layout'):
            self.raw()

    def test_selection_hash_cannot_authorize_different_selection(self):
        self.padded[0]['selections'][0]['ranges'] = [[0, 96]]
        self.padded[0]['selectionSHA256'] = base.digest(base.canonical(self.padded[0]['selections']))
        with self.assertRaisesRegex(ValueError, 'selection differs'):
            self.raw()

    def test_end_padding_geometry_crop_and_native_assertion_rejected(self):
        self.padded[0]['cropRows'] = [130, 260]
        with self.assertRaisesRegex(ValueError, 'Padding/crop'):
            self.raw()
        self.padded[0]['cropRows'] = [0, 130]
        self.padded[0]['appendedZeroRows'] = True
        with self.assertRaisesRegex(ValueError, 'Padding/crop'):
            self.raw()
        self.padded[0]['appendedZeroRows'] = 130
        self.padded[0]['zeroPaddingValidated'] = 1
        with self.assertRaisesRegex(ValueError, 'zero-padding'):
            self.raw()

    def test_padded_tail_and_crop_are_independently_checked(self):
        output = self.padded[1]['paddedOutput']
        output['values'][130] = 1.0
        output['logicalBytesSHA256'] = base.digest(base.logical_bytes(output['values'], 'bfloat16'))
        with self.assertRaisesRegex(ValueError, 'tail is not zero'):
            self.raw()
        output['values'][130] = 0.0
        output['values'][0] += 1.0
        output['logicalBytesSHA256'] = base.digest(base.logical_bytes(output['values'], 'bfloat16'))
        with self.assertRaisesRegex(ValueError, 'crop bytes'):
            self.raw()

    def test_metadata_widening_hash_bound_to_source_bytes(self):
        self.wide[2]['fusedScales']['logicalBytesSHA256'] = '0' * 64
        self.raw()  # Raw values cannot establish a matrix's model provenance.
        with self.assertRaisesRegex(ValueError, 'float32.rank1.scales'):
            self.source()

    def test_padding_weight_scale_and_bias_bytes_all_bound(self):
        for field, suffix in [('fusedWeight', 'weight'), ('fusedScales', 'scales'), ('fusedBiases', 'biases')]:
            with self.subTest(field=field):
                saved = self.padded[0][field]['logicalBytesSHA256']
                self.padded[0][field]['logicalBytesSHA256'] = '0' * 64
                with self.assertRaisesRegex(ValueError, 'padded.rank0.' + suffix):
                    self.source()
                self.padded[0][field]['logicalBytesSHA256'] = saved

    def test_corrupt_actual_source_file_rejected(self):
        raw = bytearray(self.path.read_bytes())
        raw[-1] ^= 1
        self.path.write_bytes(raw)
        with self.assertRaisesRegex(ValueError, 'norm weight'):
            self.source()

    def test_saved_baseline_metrics_are_not_trusted(self):
        self.record['componentDifferences'][0]['differingValues'] = 1
        with self.assertRaisesRegex(ValueError, 'Native difference metadata'):
            self.raw()

    def test_finite_bf16_cast_rounds_ties_to_even_and_preserves_zero(self):
        values = [1 + 2**-8, 1 + 3 * 2**-8, -1 - 2**-8, -0.0, 0.0]
        self.assertEqual(audit.cast_bytes(values, 'bfloat16'), struct.pack('<5H', 0x3f80, 0x3f82, 0xbf80, 0x8000, 0))
        self.assertEqual(audit.cast_bytes([-0.0], 'float16'), b'\x00\x80')
        with self.assertRaisesRegex(ValueError, 'Nonfinite'):
            audit.cast_bytes([float('nan')], 'bfloat16')

    def test_f16_loader_conversion_precedes_float32_widening(self):
        # 1.00390625 is representable in F16 but is a BF16 halfway case.
        path = Path(self.temp.name) / 'half.bin'
        path.write_bytes(struct.pack('<2e', 1 + 2**-8, -0.0))
        tensor = dict(path=path, base=0, dtype='F16', shape=[2, 1], data_offsets=[0, 4])
        converted, dtype, shape = audit.loaded_source_bytes(tensor, [[0, 2]], True)
        self.assertEqual((dtype, shape), ('bfloat16', [2, 1]))
        self.assertEqual(converted, struct.pack('<2H', 0x3f80, 0x8000))
        self.assertEqual(audit.widened_bytes(converted, dtype), struct.pack('<2f', 1.0, -0.0))
        unconverted, dtype, _ = audit.loaded_source_bytes(tensor, [[0, 2]], False)
        self.assertEqual(audit.widened_bytes(unconverted, dtype), struct.pack('<2f', 1 + 2**-8, -0.0))

    def test_source_bounds_and_nonfinite_metadata_rejected(self):
        tensor = dict(path=self.path, base=0, dtype='F16', shape=[2, 1], data_offsets=[0, 3])
        with self.assertRaisesRegex(ValueError, 'byte span'):
            audit.loaded_source_bytes(tensor, [[0, 2]], True)
        path = Path(self.temp.name) / 'nan.bin'
        path.write_bytes(struct.pack('<H', 0x7fc0))
        tensor = dict(path=path, base=0, dtype='BF16', shape=[1], data_offsets=[0, 2])
        with self.assertRaisesRegex(ValueError, 'Nonfinite'):
            audit.loaded_source_bytes(tensor, [[0, 1]], True)

    def test_signed_zero_cast_and_crop_use_logical_bytes(self):
        self.wide[0]['output'] = cap([1, 2, 260], [-0.0] + self.wide[0]['output']['values'][1:], 'float32')
        self.wide[0]['nativeCastOutput'] = cap([1, 2, 260], [0.0] + self.wide[0]['nativeCastOutput']['values'][1:], 'bfloat16')
        with self.assertRaisesRegex(ValueError, 'cast bytes'):
            self.raw()
        self.wide[0]['nativeCastOutput'] = cap([1, 2, 260], [-0.0] + self.wide[0]['nativeCastOutput']['values'][1:], 'bfloat16')
        self.padded[0]['output'] = cap([1, 2, 130], [-0.0] + self.padded[0]['output']['values'][1:], 'bfloat16')
        self.padded[0]['paddedOutput'] = cap([1, 2, 260], [0.0] + self.padded[0]['paddedOutput']['values'][1:], 'bfloat16')
        with self.assertRaisesRegex(ValueError, 'crop bytes'):
            self.raw()

    def test_f16_whole_source_applies_saved_bf16_policy(self):
        recode_checkpoint(self.path, 'F16')
        result = self.source()
        self.assertEqual(result['tensorCheckCount'], 37)
        self.assertFalse(result['baselineByteOracleAlsoPassed'])
        self.record['bf16ConversionEnabled'] = False
        with self.assertRaisesRegex(ValueError, 'inputNormWeight'):
            self.source()

    def test_already_float32_metadata_and_cast_are_identity_operations(self):
        recode_checkpoint(self.path, 'F32')
        tensors = base.checkpoint_headers(self.temp.name)
        # Rebind native identities to the recoded fixture; source values remain
        # equal and the native projection fixture is still semantically exact.
        for item in [self.record['normalizedInput'], self.record['firstLogits']]:
            item.update(cap(item['shape'], item['values'], 'float32'))
        raw, dtype, shape = base.selected_source_bytes(tensors[self.record['inputNormPath'] + '.weight'], [[0, 64]])
        self.record['inputNormWeight'] = audit.identity(raw, shape, dtype)
        for projection, choice in zip(self.record['sourceProjections'], base.selections(TEXT)):
            for suffix in ('scales', 'biases'):
                raw, dtype, shape = base.selected_source_bytes(tensors[projection['modulePath'] + '.' + suffix], choice['ranges'])
                projection[suffix] = audit.identity(raw, shape, dtype)
        self.record['sourceProjectionsSHA256'] = base.digest(base.canonical(self.record['sourceProjections']))
        for index, native in enumerate([self.record['full'], *self.record['ranks']]):
            for field in ('fusedScales', 'fusedBiases'):
                native[field] = copy.deepcopy(self.wide[index][field])
            native['output'].update(cap(native['output']['shape'], native['output']['values'], 'float32'))
            self.wide[index]['nativeCastOutput'] = copy.deepcopy(self.wide[index]['output'])
            if index:
                pad = self.padded[index - 1]
                pad['input'] = audit.capture_identity(self.record['normalizedInput'])
                for name in ('output', 'paddedOutput'):
                    pad[name].update(cap(pad[name]['shape'], pad[name]['values'], 'float32'))
                for suffix, field in [('scales', 'fusedScales'), ('biases', 'fusedBiases')]:
                    data = bytearray()
                    for source, choice in zip(self.record['sourceProjections'], base.selections(TEXT, index - 1)):
                        part, _, _ = base.selected_source_bytes(tensors[source['modulePath'] + '.' + suffix], choice['ranges'])
                        data.extend(part)
                    pad[field] = audit.identity(bytes(data) + bytes(130 * 4), [260, 1], 'float32')
        self.record['componentDifferences'] = native_differences(base.projection_oracle(self.record, TEXT))
        self.assertTrue(self.raw()['float32']['nativeCastFullVersusRanks']['reassembled']['exact'])
        self.assertEqual(self.source()['tensorCheckCount'], 37)


if __name__ == '__main__':
    unittest.main()
