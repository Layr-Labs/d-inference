"""Fabricated 27B output checks; no child, compiler, model or actual run input."""
import copy
import hashlib
from pathlib import Path
import sys
import unittest

BASE = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(BASE / 'run-template'))
from binding_common import canonical
from solo_contract import expected_identity, admitted, report
from solo_inputs import validate_job
from solo_fixture import receipts


class ContractChecks(unittest.TestCase):
    def setUp(self):
        tokens, expected = [17]*8192, [19]*128
        self.job = dict(schema='private_resident_solo_generation_job_v1',
            request_id='00000000-0000-4000-8000-000000000001', deployment='/invented/native',
            model_dir='/invented/model', prompt_file='/invented/prompt', expected_file='/invented/expected',
            run_dir='/invented/run', prompt_sha256=hashlib.sha256(canonical(tokens)+b'\n').hexdigest(),
            expected_sha256=hashlib.sha256(canonical(expected)+b'\n').hexdigest(), bundle_sha256='0'*64,
            native_sha256='1'*64, metallib_sha256='2129f6132794d84243c02631bc7478417dba0e0dbd10467beab56c11bf20bdd2',
            source_manifest_sha256='2'*64, stage_cut=16, output_count=128, stop_token_ids=[],
            native_seconds=300, parent_seconds=315, registered_model='registered_qwen38_27b',
            prompt_count=8192, chunk_size=512)
        self.identity = expected_identity(self.job, tokens, expected)
        self.first, self.final = receipts(self.identity)
        # Explicit fabricated model payload metadata, not copied model arrays.
        self.final['source'].update(sourceModelTensorBytes=15_132_802_048, layerCount=64)
        self.final['sourceLoad'].update(tensorCount=1847, sourceTensorCount=1847,
            loadedTensorBytes=15_132_802_048, sourceModelTensorBytes=15_132_802_048)
        self.final['resources']['authorizedTensorCount'] = 1847
        kernel = self.final['kernelEligibility']
        kernel.update(gatedDeltaLayers=48, fusedProjectionLayers=48)
        kernel['warmupDispatch'].update(nativePrefillCalls=768, nativeDecodeCalls=6096)

    def check(self, value=None):
        first = admitted(canonical(self.first), self.identity)
        return report(canonical(value or self.final), self.identity, first, 1, Path('/invented/native'))

    def test_full_fabricated_27b_cohort(self):
        result = self.check()
        self.assertEqual(len(result['requests']), 4)
        self.assertTrue(result['allRequestStateRetired'])

    def test_old_or_incomplete_warmup_counts_refused(self):
        for key, value in [('nativePrefillCalls',384), ('nativeDecodeCalls',3048),
                           ('nativePrefillCalls',767), ('operationsFallbackCalls',1)]:
            bad = copy.deepcopy(self.final); bad['kernelEligibility']['warmupDispatch'][key] = value
            with self.subTest(key=key, value=value), self.assertRaises(ValueError): self.check(bad)

    def test_old_source_inventory_refused(self):
        for key, value in [('tensorCount',927), ('loadedTensorBytes',5_038_041_600)]:
            bad = copy.deepcopy(self.final); bad['sourceLoad'][key] = value
            with self.subTest(key=key), self.assertRaises(ValueError): self.check(bad)

    def test_partial_or_unretired_cohort_refused(self):
        bad = copy.deepcopy(self.final); bad['requests'].pop()
        with self.assertRaises(ValueError): self.check(bad)
        bad = copy.deepcopy(self.final); bad['allRequestStateRetired'] = False
        with self.assertRaises(ValueError): self.check(bad)

    def test_template_cannot_run_before_actual_build_binding(self):
        with self.assertRaises(ValueError): validate_job(self.job)


if __name__ == '__main__':
    unittest.main()
