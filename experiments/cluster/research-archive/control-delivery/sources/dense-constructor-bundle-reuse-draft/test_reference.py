"""Invented temporary bundles only; no native/model/control-driver execution."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parent
def load(path, name):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module

helper = load(HERE/'owned_bundle_reference.py','_reuse_test_helper')
artifact_path = Path('/Users/developer/DarkbloomDev/d-inference/experiments/cluster/runtime/artifacts.py')
assert hashlib.sha256(artifact_path.read_bytes()).hexdigest() == '245a6bccda22952fb549a84386737b927c306bc7a460c051920389c28e33233d'
artifacts = load(artifact_path,'_reuse_test_artifacts')
driver = load(HERE/'run_dense_constructor_probe_v2.py','_reuse_test_driver')


class ReferenceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.bundle, self.runtime = self.root/'owned', self.root/'runtime'
        self.bundle.mkdir(mode=0o700)
        self.runtime.mkdir(mode=0o700)
        entries=[]
        for name, data in [('cluster-inference',b'invented non-executable content'),
                           ('mlx.metallib',b'invented'), ('rank_worker.py',b'worker'),('artifacts.py',b'helper')]:
            path=self.bundle/name;path.write_bytes(data);path.chmod(0o500 if name=='cluster-inference' else 0o400)
            entries.append(dict(path=name,size_bytes=len(data),sha256=hashlib.sha256(data).hexdigest()))
            if name in ('rank_worker.py','artifacts.py'):
                (self.runtime/name).write_bytes(data)
        manifest=self.bundle/'bundle.json'
        manifest.write_text(json.dumps(dict(schema_version=1,files=entries)))
        manifest.chmod(0o400)
        self.pin=artifacts.file_sha256(manifest)
        self.native=artifacts.file_sha256(self.bundle/'cluster-inference')
        self.dest=self.root/'reference'

    def create(self, manifest=None, native=None):
        return helper.create_reference(self.bundle,self.dest,manifest or self.pin,native or self.native,self.runtime,artifacts)

    def test_reference_without_copy_and_unchanged_origin(self):
        before={p.name:(p.stat().st_ino,p.read_bytes(),p.stat().st_mode) for p in self.bundle.iterdir()}
        record=self.create()
        self.assertTrue(self.dest.is_symlink())
        self.assertFalse(record['copied'])
        helper.check_reference(self.dest,record,self.runtime,artifacts)
        self.assertEqual(before,{p.name:(p.stat().st_ino,p.read_bytes(),p.stat().st_mode) for p in self.bundle.iterdir()})

    def test_wrong_pins_refuse_before_link(self):
        for kwargs in ({'manifest':'0'*64},{'native':'0'*64}):
            with self.assertRaises(ValueError):self.create(**kwargs)
            self.assertFalse(self.dest.is_symlink())

    def test_writable_member_refused(self):
        (self.bundle/'mlx.metallib').chmod(0o600)
        with self.assertRaisesRegex(ValueError,'read-only'):self.create()

    def test_unlisted_member_refused(self):
        p=self.bundle/'extra';p.write_bytes(b'extra');p.chmod(0o400)
        with self.assertRaisesRegex(ValueError,'tree differs'):self.create()

    def test_member_symlink_refused(self):
        p=self.bundle/'mlx.metallib';p.unlink();p.symlink_to(self.runtime/'artifacts.py')
        with self.assertRaisesRegex(ValueError,'symlink'):self.create()

    def test_runtime_drift_refused(self):
        (self.runtime/'rank_worker.py').write_bytes(b'changed')
        with self.assertRaisesRegex(ValueError,'fresh source archive'):self.create()

    def test_after_creation_file_drift_refused(self):
        record=self.create();p=self.bundle/'mlx.metallib';p.chmod(0o600);p.write_bytes(b'changed!');p.chmod(0o400)
        with self.assertRaises(ValueError):helper.check_reference(self.dest,record,self.runtime,artifacts)

    def test_after_creation_link_drift_refused(self):
        record=self.create();self.dest.unlink();self.dest.symlink_to(self.runtime,target_is_directory=True)
        with self.assertRaisesRegex(ValueError,'realpath changed'):helper.check_reference(self.dest,record,self.runtime,artifacts)

    def test_unpaired_flags_stop_before_existing_driver_io(self):
        prefix=['driver','--profile','registered_qwen38_27b','--expected-native-sha256','0'*64,'--output',str(self.root/'new')]
        for suffix in (['--reuse-bundle',str(self.bundle)],['--expected-bundle-manifest-sha256',self.pin]):
            with patch.object(sys,'argv',prefix+suffix),self.assertRaisesRegex(ValueError,'requires both'):
                driver.main()
            self.assertFalse((self.root/'new').exists())


if __name__=='__main__':unittest.main()
