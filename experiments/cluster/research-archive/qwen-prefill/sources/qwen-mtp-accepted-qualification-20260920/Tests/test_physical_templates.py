"""Synthetic metadata rendering only; no actual artifact or process is fabricated."""
import ast
import json
from pathlib import Path
import tempfile
import unittest

from common import canonical, REMOTE, replace, sha
from reference_template import stage


class PhysicalTemplateTests(unittest.TestCase):
    def test_actual_metadata_is_threaded_to_closed_reference_job_and_bundle(self):
        b=dict(requestID='abcdef01-1234-4000-8000-000000000001',promptSHA256='a'*64,
               sourceSnapshotSHA256='b'*64,referenceSHA256='c'*64,workerSHA256='d'*64,bundleSHA256='e'*64)
        bundle=dict(schema='qwen_mtp_accepted_native_bundle_v1',files=[],buildReceiptSHA256='f'*64,
                    sourceSnapshotSHA256='b'*64,dependencySnapshotSHA256='0'*64,acceptedManifestSHA256='1'*64,
                    nativeMTPQualified=False,correctnessOnly=True,servingEnabled=False,physicalExecuted=False)
        with tempfile.TemporaryDirectory() as name:
            p=stage(Path(name),b,bundle,canonical(list(range(32))))
            job=json.loads((p/'inputs/job.json').read_bytes())
            self.assertEqual((job['prompt_count'],job['chunk_size'],job['output_count'],job['stage_cut']),(32,16,8,4))
            self.assertEqual(job['native_sha256'],b['referenceSHA256'])
            self.assertEqual(job['deployment'],REMOTE+'/native')
            self.assertEqual((job['native_seconds'],job['parent_seconds']),(300,315))
            text=(p/'package/reference_inputs.py').read_text()
            self.assertIn('Exactly four same-source bundle members required',text)
            self.assertNotIn('d71726f61ff5cef6c2a7722b0a06fb7d6b7c61af2cb081ff3aef083803f32aac',text)
            for source in p.rglob('*.py'):ast.parse(source.read_text())
            for root in (p,p/'package'):
                for row in json.loads((root/'manifest.json').read_bytes())['files']:
                    self.assertEqual(sha(root/row['path']),row['sha256'])

    def test_ambiguous_or_missing_preimage_refuses(self):
        for text in ['absent','old old']:
            with self.assertRaises(ValueError):replace(text,'old','new')


if __name__=='__main__':unittest.main()
