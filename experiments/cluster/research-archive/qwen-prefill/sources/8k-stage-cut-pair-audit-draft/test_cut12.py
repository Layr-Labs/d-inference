"""Fixed-cut boundaries and coherent stale-plan negatives; fabricated records."""
import copy
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import audit_cut12_pair as adapter
import cut12_pair_fixture as fixture
import cut12_pair_final as final
import qwen_long_prefill_pair_cut12_audit as audit


class Cut12Tests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.a, cls.prompt, cls.rows = fixture.fixture()

    def check(self, rows):
        return audit.check_pair(self.a, rows, self.prompt, self.a.sha(self.prompt))

    def rejected(self, mutate):
        rows = copy.deepcopy(self.rows)
        mutate(rows)
        with self.assertRaises((ValueError, KeyError, TypeError)):
            self.check(rows)

    def test_complete_exact_split_and_global_state_bytes(self):
        s = self.check(self.rows)
        self.assertEqual(s['stageStateComponents'], [27,45])
        self.assertEqual(s['stageLogicalStateBytes'], [119980044,199966740])
        loads = self.rows[1]['stageLoads']
        self.assertEqual([len(x['activeTensors']) for x in loads], [348,579])
        self.assertEqual([x['loadedTensorBytes'] for x in loads], [2032294848,3005746752])
        self.assertEqual([x['inertTensorBytes'] for x in loads], [16384,8192])
        self.assertEqual(loads[0]['planSHA256'], '8c3fef079cc82295d70851ef9d9193954afc0d008ad09ce239baaa1a51391fed')

    def test_coherent_old_half_pair_is_refused(self):
        path = Path(__file__).resolve().parent.parent/'long-prefill-pair-audit-draft/pair_fixture.py'
        spec = importlib.util.spec_from_file_location('only_fake_old_half_pair', path)
        old = importlib.util.module_from_spec(spec); spec.loader.exec_module(old)
        _, prompt, rows = old.fixture()
        self.assertEqual(prompt, self.prompt)
        with self.assertRaisesRegex(ValueError, 'planSHA256'):
            self.check(rows)

    def test_nested_reference_rehashed_with_old_plan_is_refused(self):
        def mutate(rows):
            e = rows[0]['reference']
            e['execution']['source']['planSHA256'] = '2b5aa52cab49c12cfa44f2348326f956127d2ca15b1c55b5632f447901e56293'
            e['fingerprint'] = self.a.evidence_fingerprint(e)
            rows[1]['comparison']['baselineEvidenceFingerprint'] = e['fingerprint']
        self.rejected(mutate)

    def test_rehashed_whole_global_union_with_wrong_owner_is_refused(self):
        def mutate(rows):
            states = [x['finalState'] for x in rows[1]['comparison']['finalDigests']]
            moved = [e for e in states[1]['entries'] if e['globalLayerIndex'] == 12]
            states[1]['entries'] = [e for e in states[1]['entries'] if e['globalLayerIndex'] != 12]
            states[0]['entries'] += moved
            for record in rows[1]['comparison']['finalDigests']:
                state = record['finalState']
                state['entries'].sort(key=lambda e:(e['globalLayerIndex'],e['component']))
                state['logicalByteCount'] = sum(e['byteCount'] for e in state['entries'])
                state['fingerprint'] = self.a.state_fingerprint(state['entries'])
                record['fingerprint'] = final.final_fingerprint(self.a, record)
        self.rejected(mutate)

    def test_local_tensor_index_and_construction_identity_refused(self):
        for mutation in (
            lambda r:r[1]['stageLoads'][1]['activeTensors'][0].update(localName='language_model.model.layers.12.fake.weight'),
            lambda r:r[1]['stageLoads'][0].update(constructionConfigurationSHA256=r[1]['stageLoads'][1]['constructionConfigurationSHA256']),
            lambda r:r[1]['stageLoads'][1].update(stagePlanSHA256=r[1]['stageLoads'][0]['stagePlanSHA256'])):
            with self.subTest(mutation=mutation): self.rejected(mutation)

    def test_file_adapter_fixed_scope_and_complete_records(self):
        raw = b'\n'.join(json.dumps(row,separators=(',',':'),allow_nan=False).encode() for row in self.rows)+b'\n'
        with tempfile.TemporaryDirectory(prefix='cut12-long-pair-fake-') as td:
            out,prompt = Path(td)/'stdout.jsonl',Path(td)/'prompt.json'
            out.write_bytes(raw); prompt.write_bytes(self.prompt)
            result = adapter.validate(out,prompt,self.a.sha(self.prompt))
            self.assertTrue(result['sameRunReferenceValidatedAgainstSelectedPlan'])
            self.assertFalse(result['oldHalfReferenceRelabeled'])
            self.assertEqual(result['sourceLayerRanges'],[[0,12],[12,32]])
            out.write_bytes(raw[:-1])
            with self.assertRaises(ValueError): adapter.validate(out,prompt,self.a.sha(self.prompt))
            with self.assertRaises(ValueError): adapter.validate(prompt,prompt,self.a.sha(self.prompt))
            out.unlink(); out.symlink_to(prompt)
            with self.assertRaises(ValueError): adapter.validate(out,prompt,self.a.sha(self.prompt))

    def test_file_adapter_detects_changed_input_after_numeric_replay(self):
        raw = b'\n'.join(json.dumps(row,separators=(',',':'),allow_nan=False).encode() for row in self.rows)+b'\n'
        with tempfile.TemporaryDirectory(prefix='cut12-long-pair-fake-') as td:
            out,prompt = Path(td)/'stdout.jsonl',Path(td)/'prompt.json'
            out.write_bytes(raw); prompt.write_bytes(self.prompt)
            original = audit.check_pair
            def mutation(*args):
                result = original(*args)
                prompt.write_bytes(self.prompt+b' ')
                return result
            with patch.object(audit,'check_pair',side_effect=mutation),self.assertRaisesRegex(ValueError,'changed during replay'):
                adapter.validate(out,prompt,self.a.sha(self.prompt))


if __name__ == '__main__': unittest.main()
