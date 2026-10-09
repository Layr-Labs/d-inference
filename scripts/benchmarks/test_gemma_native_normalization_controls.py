import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import struct
import sys
import tempfile
import types
import unittest
from unittest.mock import patch
import zipfile


SCRIPT = Path(__file__).with_name('gemma-native-normalization-controls.py')
ROOT = SCRIPT.parents[2]
EVIDENCE = ROOT / 'docs/reports/evidence/gemma-normalization-2026-10-09'
SPEC = importlib.util.spec_from_file_location('gemma_normalization_controls', SCRIPT)
CONTROLS = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CONTROLS)


def frozen_runs():
    return json.loads((EVIDENCE / 'runs.json').read_text())


def evidence_bytes(name):
    path = EVIDENCE / name
    if path.is_file():
        return path.read_bytes()
    if name.endswith('.md'):
        with zipfile.ZipFile(EVIDENCE / 'raw-cell-reports.zip') as archive:
            return archive.read(name)
    return path.read_bytes()


def cell_report(cell):
    return f'- optimization-cell-json [perf/v2/B{cell["batch"]}]: ' + json.dumps(cell)


class CompleteReceiptTests(unittest.TestCase):
    def test_every_frozen_cell_has_complete_generation_identity(self):
        for row in frozen_runs():
            name = f'L{row["length"]}-B{row["batch"]}-R{row["repeat"]}-{row["arm"]}'
            with self.subTest(cell=name):
                parsed = CONTROLS.complete_cell_receipt(
                    evidence_bytes(name + '.md').decode(), name,
                    row['batch'], row['length'])
                self.assertEqual(parsed, row['cell'])

    def test_missing_or_incomplete_identities_are_refused(self):
        original = frozen_runs()[0]['cell']
        mutations = {
            'missing finish': lambda c: c['tokenReceipts'][0].pop('finishReason'),
            'empty finish': lambda c: c['tokenReceipts'][0].update(finishReason=''),
            'truncated tokens': lambda c: c['tokenReceipts'][0]['tokenIDs'].pop(),
            'boolean token': lambda c: c['tokenReceipts'][0]['tokenIDs'].__setitem__(0, True),
            'wrong count': lambda c: c['tokenReceipts'][0].update(completionTokens=63),
            'wrong prompt': lambda c: c['tokenReceipts'][0].update(promptTokens=127),
            'missing requests': lambda c: c.update(tokenReceipts=[]),
            'wrong engine': lambda c: c.update(engine='paged'),
            'wrong batch': lambda c: c.update(batch=2),
            'nonfinite timing': lambda c: c.update(itlP50Ms=float('nan')),
        }
        for name, mutate in mutations.items():
            with self.subTest(case=name):
                cell = copy.deepcopy(original)
                mutate(cell)
                with self.assertRaises(RuntimeError):
                    CONTROLS.complete_cell_receipt(cell_report(cell), name, 1, 128)

    def test_duplicate_cell_receipts_are_refused(self):
        report = cell_report(frozen_runs()[0]['cell'])
        with self.assertRaisesRegex(RuntimeError, 'unique cell'):
            CONTROLS.complete_cell_receipt(report + '\n' + report, 'duplicate', 1, 128)


class FrozenSummaryTests(unittest.TestCase):
    def test_summary_replays_without_any_numerical_change(self):
        expected = json.loads((EVIDENCE / 'summary.json').read_text())
        actual = CONTROLS.summarize_controls(frozen_runs())
        self.assertEqual(actual, expected)
        self.assertTrue(actual['quality_gate'])
        self.assertFalse(actual['benefit_gate'])

    def test_incomplete_or_duplicated_pairs_are_refused(self):
        rows = frozen_runs()
        with self.assertRaisesRegex(RuntimeError, 'all 24'):
            CONTROLS.summarize_controls(rows[:-1])
        rows[1] = copy.deepcopy(rows[0])
        with self.assertRaisesRegex(RuntimeError, 'unique native/candidate'):
            CONTROLS.summarize_controls(rows)

    def test_native_repeat_instability_fails_identity_gate(self):
        rows = frozen_runs()
        repeated_native = next(
            row for row in rows
            if row['arm'] == 'native' and row['repeat'] == 1)
        repeated_native['cell']['tokenReceipts'][0]['tokenIDs'][0] += 1
        actual = CONTROLS.summarize_controls(rows)
        self.assertFalse(actual['native_repeats_stable'])
        self.assertFalse(actual['quality_gate'])

    def test_frozen_artifacts_and_original_scripts_match_their_manifests(self):
        for manifest_name in ['artifact-manifest.json', 'original-script-manifest.json']:
            manifest = json.loads((EVIDENCE / manifest_name).read_text())
            for name, receipt in manifest.items():
                with self.subTest(manifest=manifest_name, artifact=name):
                    payload = evidence_bytes(name)
                    self.assertEqual(len(payload), receipt['bytes'])
                    self.assertEqual(hashlib.sha256(payload).hexdigest(), receipt['sha256'])

    def test_raw_report_archive_retains_original_member_names_and_bytes(self):
        receipt = json.loads((EVIDENCE / 'raw-cell-report-archive.json').read_text())
        archive_path = EVIDENCE / receipt['archive']
        payload = archive_path.read_bytes()
        self.assertEqual(len(payload), receipt['bytes'])
        self.assertEqual(hashlib.sha256(payload).hexdigest(), receipt['sha256'])
        with zipfile.ZipFile(archive_path) as archive:
            self.assertEqual(sorted(archive.namelist()), receipt['members'])
        manifest = json.loads((EVIDENCE / receipt['original_manifest']).read_text())
        self.assertEqual(receipt['members'], sorted(
            name for name in manifest if name.endswith('.md')))


class ImageAndLeaseTests(unittest.TestCase):
    def images(self, root):
        images = {}
        for arm in ['native', 'candidate']:
            path = root / arm
            path.mkdir()
            (path / 'BenchCBv2').write_bytes(arm.encode())
            (path / 'mlx.metallib').write_bytes(b'matched source library')
            receipt = {
                'original_native_normalizer': arm == 'native',
                'benchmark_binary_sha256': CONTROLS.sha256_file(path / 'BenchCBv2'),
                'metallib_sha256': CONTROLS.sha256_file(path / 'mlx.metallib'),
                'token_receipts': True,
            }
            (path / 'build-receipt.json').write_text(json.dumps(receipt))
            images[arm] = path
        return images

    def test_matching_images_pass_and_mutated_binary_is_refused(self):
        with tempfile.TemporaryDirectory() as temporary:
            images = self.images(Path(temporary))
            CONTROLS.validate_images(images)
            (images['candidate'] / 'BenchCBv2').write_bytes(b'changed')
            with self.assertRaisesRegex(RuntimeError, 'does not match'):
                CONTROLS.validate_images(images)

    def test_provenance_guards_remain_active_under_optimized_python(self):
        with tempfile.TemporaryDirectory() as temporary:
            images = self.images(Path(temporary))
            (images['candidate'] / 'BenchCBv2').write_bytes(b'changed')
            code = (
                'from pathlib import Path; import runpy; '
                'module=runpy.run_path(' + repr(str(SCRIPT)) + '); '
                'module["validate_images"]({'
                + ','.join(repr(arm) + ':Path(' + repr(str(path)) + ')'
                           for arm, path in images.items()) + '})'
            )
            result = subprocess.run(
                [sys.executable, '-B', '-O', '-c', code],
                capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('does not match its build receipt', result.stderr)

    def test_lease_uses_fresh_nonce_and_releases_on_error(self):
        with tempfile.TemporaryDirectory() as temporary:
            lock = Path(temporary) / 'model.lock'
            owners = []
            for _ in range(2):
                with CONTROLS.model_lease(lock, 'same campaign'):
                    owners.append((lock / 'owner').read_text())
                self.assertFalse(lock.exists())
            self.assertNotEqual(owners[0], owners[1])
            with self.assertRaisesRegex(RuntimeError, 'measured cell failed'):
                with CONTROLS.model_lease(lock, 'same campaign'):
                    raise RuntimeError('measured cell failed')
            self.assertFalse(lock.exists())

    def test_lease_refuses_collision_and_preserves_replaced_owner(self):
        with tempfile.TemporaryDirectory() as temporary:
            lock = Path(temporary) / 'model.lock'
            with CONTROLS.model_lease(lock, 'same campaign'):
                with self.assertRaises(FileExistsError):
                    with CONTROLS.model_lease(lock, 'other campaign'):
                        self.fail('colliding lease must not be acquired')
                (lock / 'owner').write_text('replacement owner\n')
            self.assertEqual((lock / 'owner').read_text(), 'replacement owner\n')


class RawProbeHeaderTests(unittest.TestCase):
    def test_invalid_norm_headers_or_truncated_payload_fail_before_mlx_use(self):
        mlx = types.ModuleType('mlx')
        mlx.core = types.ModuleType('mlx.core')
        mlx.core.array = object
        modules = {'mlx': mlx, 'mlx.core': mlx.core, 'numpy': types.ModuleType('numpy')}
        with patch.dict(sys.modules, modules):
            spec = importlib.util.spec_from_file_location(
                'raw_gemma_probe', SCRIPT.with_name('gemma-raw-kv-probe.py'))
            probe = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(probe)
        name = 'language_model.model.layers.5.self_attn.k_norm.weight'
        for shape, dtype, stop, payload in [
            ([513], 'BF16', 1_024, b'\0' * 1_024),
            ([512], 'F32', 1_024, b'\0' * 1_024),
            ([512], 'BF16', 1_025, b'\0' * 1_025),
            ([512], 'BF16', 1_024, b'\0' * 1_023),
        ]:
            with self.subTest(shape=shape, dtype=dtype, bytes=len(payload)):
                with tempfile.TemporaryDirectory() as temporary:
                    root = Path(temporary)
                    (root / 'model.safetensors.index.json').write_text(json.dumps(
                        {'weight_map': {name: 'norm.safetensors'}}))
                    header = json.dumps({name: {
                        'shape': shape, 'dtype': dtype, 'data_offsets': [0, stop]
                    }}).encode()
                    (root / 'norm.safetensors').write_bytes(
                        struct.pack('<Q', len(header)) + header + payload)
                    with self.assertRaisesRegex(RuntimeError, '512 BF16 values'):
                        probe.load_norm(root, 5)


if __name__ == '__main__':
    unittest.main()
