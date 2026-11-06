import hashlib
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from dataclasses import replace
from unittest.mock import patch

from binding_common import canonical
from reference_contract import admitted, expected_identity
from reference_inputs import (METALLIB, NATIVE, SOURCE, Pins, native_spec, validate_job,
                              verify_inputs)
from reference_resources import ResourceGate
from run_reference import serve
from worker_contract import WorkerSpec
from reference_profiles import registered_profile

HERE = Path(__file__).parent


def job_at(root, model='registered_qwen35_9b', prompt_count=8192, chunk_size=512,
           output_count=128, stop_token_ids=None):
    return dict(schema='private_registered_full_generation_reference_job_v1',
        request_id='01234567-89ab-cdef-0123-456789abcdef', deployment=str(root/'bundle'),
        model_dir=str(root/'model'), prompt_file=str(root/'input.json'),
        prompt_sha256=hashlib.sha256(canonical([17]*prompt_count)).hexdigest(), run_dir=str(root/'run'),
        bundle_sha256='b'*64, native_sha256=NATIVE, metallib_sha256=METALLIB,
        source_manifest_sha256=SOURCE, stage_cut=4, output_count=output_count, stop_token_ids=stop_token_ids or [],
        registered_model=model, prompt_count=prompt_count, chunk_size=chunk_size,
        native_seconds=300, parent_seconds=315)


class Checks(unittest.TestCase):
    def child(self, case, gate=None, pins=None, timeout=5, job_changes=None):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            job = job_at(root, **(job_changes or {})); run = root/'run'; run.mkdir()
            jobfile = root/'job.json'; jobfile.write_bytes(canonical(job)+b'\n')
            spec = WorkerSpec((sys.executable, '-B', str(HERE/'fabricated_reference.py'), case, str(jobfile)),
                              dict(os.environ), 'solo', None)
            result = serve(job, spec, [17]*job['prompt_count'], run, gate or (lambda _: None), pins or Pins(), timeout=timeout)
            receipt = json.loads((run/'terminal.json').read_text())
            self.assertTrue(receipt['nativeLeaderReaped'])
            self.assertTrue(receipt['ownedGroupFenceComplete'])
            self.assertFalse(receipt['independentNumericalComparisonPerformed'])
            self.assertFalse(receipt['sourceToBinaryBuildIndependentlyVerified'])
            for stream in receipt['streams']:
                file = Path(stream['path'])
                self.assertEqual(hashlib.sha256(file.read_bytes()).hexdigest(), stream['sha256'])
                self.assertEqual(file.stat().st_mode & 0o777, 0o600)
            with self.assertRaises(ProcessLookupError):
                os.kill(receipt['owner']['nativePID'], 0)
            return result, receipt

    def test_complete_actual_python_child(self):
        result, receipt = self.child('good')
        self.assertEqual(result, 0); self.assertEqual(receipt['recordsAccepted'], 2)
        self.assertEqual(receipt['nativeExitCodes'], [0]); self.assertTrue(receipt['outputComplete'])

    def test_actual_child_failures_are_retained_and_fenced(self):
        for case in ('incomplete', 'report-first', 'malformed', 'wrong-request', 'failed-report',
                     'short-row', 'wrong-pid', 'extra', 'nonzero', 'stderr', 'truncated'):
            with self.subTest(case=case):
                result, receipt = self.child(case)
                self.assertEqual(result, 1); self.assertEqual(receipt['status'], 'failed')
                self.assertIsNotNone(receipt['primaryFailure'])

    def test_actual_child_absolute_deadline(self):
        result, receipt = self.child('timeout', timeout=1)
        self.assertEqual(result, 1); self.assertLess(receipt['elapsedSeconds'], 4)

    def test_live_gate_failure_fences_launched_child(self):
        def gate(phase):
            if phase == 'native-report':
                raise ValueError('fabricated resource refusal')
        result, receipt = self.child('timeout', gate=gate)
        self.assertEqual(result, 1); self.assertIn('resource refusal', receipt['primaryFailure'])

    def test_postflight_input_failure_invalidates_complete_output(self):
        class FailedPins:
            def recheck(self):
                raise ValueError('fabricated changed source')
        result, receipt = self.child('good', pins=FailedPins())
        self.assertEqual(result, 1); self.assertTrue(receipt['outputComplete'])
        self.assertEqual(receipt['postflightErrors'][0]['operation'], 'source_input_recheck')

    def test_job_and_exact_twelve_pair_command(self):
        job = job_at(Path('/invented'))
        validate_job(job)
        spec = native_spec(job)
        self.assertEqual(len(spec.argv), 25)
        self.assertEqual(spec.argv[-2:], ('--timeout-seconds', '300'))
        self.assertNotIn('JACCL_RANK', spec.env)
        for key, value in [('output_count', True), ('native_seconds', 301), ('parent_seconds', 316),
                           ('stage_cut', 5), ('stop_token_ids', [True]), ('native_sha256', 'a'*64)]:
            broken = dict(job, **{key:value})
            with self.subTest(key=key), self.assertRaises(ValueError):
                validate_job(broken)

    def test_strict_duplicate_and_nonfinite_json(self):
        expected = expected_identity(job_at(Path('/invented')), [17]*8192)
        for raw in (b'{"kind":1,"kind":2}', b'{"kind":NaN}', b'{"kind":1e999}'):
            with self.assertRaises(ValueError):
                admitted(raw, expected)

    def test_live_resource_gate_preserves_refused_sample(self):
        rows = []
        sample = dict(actualFreeBytes=5*1024**3, pressureLevel=1, reportedSwapBytes='0', acPower=True,
                      startedMonotonicNS=1, completedMonotonicNS=2)
        gate = ResourceGate(rows.append, sample=lambda:sample)
        with self.assertRaises(ValueError):
            gate('prelaunch')
        self.assertEqual(len(rows), 1); self.assertEqual(rows[0]['actualFreeBytes'], 5*1024**3)

    def test_snapshot_change_and_symlink_refuse(self):
        with tempfile.TemporaryDirectory() as directory:
            file = Path(directory)/'input'; file.write_bytes(b'a')
            pins = Pins(); pins.read(file, 10)
            file.write_bytes(b'b')
            with self.assertRaises(ValueError): pins.recheck()
            link = Path(directory)/'link'; link.symlink_to(file)
            with self.assertRaises(OSError): Pins().read(link, 10)

    def test_three_member_bundle_and_model_metadata_pins(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve(); bundle = root/'bundle'; model = root/'model'
            bundle.mkdir(); model.mkdir()
            job = job_at(root)
            payloads = {'cluster-inference': b'fabricated executable', 'mlx.metallib': b'fabricated library',
                        'mlx-swift-lm_MLXLMCommon.bundle/pagedattention.metal': b'fabricated source'}
            hashes = {n:hashlib.sha256(raw).hexdigest() for n, raw in payloads.items()}
            for name, raw in payloads.items():
                file = bundle/name; file.parent.mkdir(exist_ok=True)
                file.write_bytes(raw)
            (bundle/'cluster-inference').chmod(0o700)
            metadata = dict(schemaVersion=1, scope='Fabricated test only', sourceManifestSHA256=SOURCE,
                files=[dict(path=n, sha256=hashes[n], bytes=len(raw)) for n, raw in payloads.items()])
            (bundle/'bundle.json').write_bytes(canonical(metadata))
            job['bundle_sha256'] = hashlib.sha256(canonical(metadata)).hexdigest()
            for name in ('config.json', 'manifest.json'):
                (model/name).write_bytes(b'{}')
            (root/'input.json').write_bytes(canonical([17]*8192))
            smallpin = hashlib.sha256(b'{}').hexdigest()
            with patch.multiple('reference_inputs', NATIVE=hashes['cluster-inference'],
                    METALLIB=hashes['mlx.metallib'], PAGED=hashes['mlx-swift-lm_MLXLMCommon.bundle/pagedattention.metal'],
                    ), patch('reference_inputs.registered_profile', return_value=replace(
                        registered_profile(job['registered_model']), configuration=smallpin, manifest=smallpin)):
                pins = Pins(); raw, tokens = verify_inputs(job, pins)
                self.assertEqual(len(tokens), 8192); pins.recheck()
                (bundle/'unexpected').write_bytes(b'x')
                with self.assertRaises(ValueError): verify_inputs(job, Pins())
                (bundle/'unexpected').unlink()
                (bundle/'mlx.metallib').write_bytes(b'changed')
                with self.assertRaises(ValueError): verify_inputs(job, Pins())


if __name__ == '__main__':
    unittest.main()
