"""Fabricated numerical envelopes and retained metadata only."""
import copy
import json
from pathlib import Path
import subprocess
import sys
import unittest
from audit_scope import AuditScope, CATALOG, pinned_scope
from audit_reference import check_reference
from audit_candidate import compare
from fabricated import fixture, reference_bytes
from recorded_math import canonical

BASE = Path(__file__).resolve().parent
OLD = BASE.parent / 'registered-generation-numerical-audit-draft-20260915'
REQUEST = '20801ced-ca29-4faf-b71a-9ebbe1886a14'


class Cut16Tests(unittest.TestCase):
    def test_catalog_only_adds_actual_metadata_cut_and_preserves_closed_identity(self):
        old = json.loads((OLD / 'registered_profiles.json').read_bytes())
        new = copy.deepcopy(CATALOG)
        actual = new['registered_qwen38_27b']['plans'].pop('16')
        self.assertEqual(new, old)
        meta = json.loads((BASE / 'inputs/recording-metadata.json').read_bytes())
        self.assertEqual(actual, dict(fingerprint=meta['planSHA256'], stages=meta['stagePlanSHA256'],
                                     constructions=meta['constructionConfigurationSHA256']))
        request = json.loads((BASE / 'inputs/request.json').read_bytes())
        self.assertEqual(pinned_scope(request, meta).cut, 16)
        for field in ['planSHA256', 'constructionConfigurationSHA256', 'stagePlanSHA256']:
            altered = copy.deepcopy(meta)
            altered[field] = '0' * 64 if field == 'planSHA256' else ['0' * 64] * 2
            with self.assertRaises(ValueError): pinned_scope(request, altered)

    def test_full_cut16_fixture_compares_complete_global_state_and_row(self):
        scope = AuditScope('registered_qwen38_27b', 32, 16, 128, 16)
        prompt, context, admitted, report, expected, candidates = fixture(scope, REQUEST)
        result = compare(check_reference(reference_bytes(admitted, report), context), candidates, expected, context)
        self.assertEqual(result['stageStateEntryCounts'], [36, 108])
        self.assertEqual(result['orderedStateEntriesCompared'], 144)
        self.assertEqual(result['finalNativeBF16RowBytesCompared'], 496640)
        self.assertEqual((result['comparedSelectedTokenCount'], result['finalCompletedFrames'], result['finalCommittedTokens']), (128, 129, 159))
        self.assertFalse(result['physicalTransferQualified'])

    def test_cut32_reference_is_refused_under_cut16_binding(self):
        _, context, admitted, report, _, _ = fixture(AuditScope('registered_qwen38_27b', 32, 16, 128, 16), REQUEST)
        _, _, old_admitted, old_report, _, _ = fixture(AuditScope('registered_qwen38_27b', 32, 16, 128, 32), REQUEST)
        with self.assertRaises(ValueError): check_reference(reference_bytes(old_admitted, old_report), context)
        report['execution']['finalState']['entries'][0]['globalLayerIndex'] = 16
        with self.assertRaises(ValueError): check_reference(reference_bytes(admitted, report), context)

    def test_cut32_result_remains_byte_identical_to_frozen_comparator(self):
        args = (AuditScope('registered_qwen38_27b', 32, 16, 128, 32), REQUEST)
        _, context, admitted, report, expected, candidates = fixture(*args)
        result = canonical(compare(check_reference(reference_bytes(admitted, report), context), candidates, expected, context))
        script = ('from audit_scope import AuditScope;from fabricated import fixture,reference_bytes;'
            'from audit_reference import check_reference;from audit_candidate import compare;from recorded_math import canonical;'
            'import sys;p,c,a,r,e,s=fixture(AuditScope("registered_qwen38_27b",32,16,128,32),"' + REQUEST + '");'
            'sys.stdout.buffer.write(canonical(compare(check_reference(reference_bytes(a,r),c),s,e,c)))')
        previous = subprocess.run([sys.executable, '-B', '-c', script], cwd=OLD, capture_output=True, timeout=15, check=True)
        self.assertEqual(previous.stderr, b'')
        self.assertEqual(result, previous.stdout)

    def test_storage_replays_original_then_remaps_full_inventory(self):
        from derive_storage import derive, commitment_for, prior
        value, active = derive()
        self.assertTrue(value['exactPriorCut32CommitmentAndAll1847MappingsReplayed'])
        self.assertEqual(list(map(len, active)), [463, 1384])
        self.assertEqual(len({x['sourceName'] for rank in active for x in rank}), 1847)
        self.assertTrue(any(x['sourceName'].startswith('language_model.model.layers.16.')
                            and x['localName'].startswith('language_model.model.layers.0.') for x in active[1]))
        values, _ = prior.load_inputs()
        report = values['constructor.stdout.jsonl']
        report['sourceTensors'][0]['byteCount'] += 2
        meta = json.loads((BASE / 'inputs/recording-metadata.json').read_bytes())
        with self.assertRaises(ValueError): commitment_for(report, meta, 16)


if __name__ == '__main__':
    unittest.main()
