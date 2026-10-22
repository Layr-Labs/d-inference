"""Fake launcher wiring; no executable, model, observer or real bundle validator runs."""
from contextlib import ExitStack, redirect_stdout
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import sys
import tempfile
import types
import unittest
from unittest.mock import patch

sys.dont_write_bytecode=True
HERE=Path(__file__).resolve().parent
spec=importlib.util.spec_from_file_location('_tiny_reuse_wiring',HERE/'run_tiny_stage_check_v2.py')
entry=importlib.util.module_from_spec(spec);spec.loader.exec_module(entry)
DIAGNOSTIC='[bf16] converted 124 params (0.1 MB) fp16→bf16 in 3 ms\n'.encode()


class Wiring(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup)
        self.root=Path(self.temp.name);self.repo=self.root/'repo'
        self.release=self.repo/'experiments/cluster/inference/.build/release';self.release.mkdir(parents=True)
        self.native=b'invented bytes; never execute';(self.release/'cluster-inference').write_bytes(self.native)
        self.old=self.root/'old-bundle';self.old.mkdir();(self.old/'cluster-inference').write_bytes(self.native)
        self.out=self.root/'run';self.calls=[]

    def invoke(self,reuse=True,stderr=b'',post_failure=False):
        calls=self.calls;root=self.root;native=self.native
        class Reference:
            checks=0
            def create_reference(self,source,destination,manifest,*_):
                calls.append('reference-create');destination.symlink_to(source,target_is_directory=True)
                return dict(manifestSHA256=manifest,copied=False,resolvedPath=str(source))
            def check_reference(self,*_):
                self.checks+=1;calls.append('reference-check')
                if post_failure and self.checks==2:raise ValueError('fake reference drift')
        def snapshot(_release,destination):
            calls.append('snapshot');destination.mkdir();(destination/'cluster-inference').write_bytes(native)
            return 'd'*64
        def archive_sources(_runtime,out):
            (out/'source-manifest.json').write_text('{}');return {'files':[]}
        def write_json(path,value):path.write_text(json.dumps(value))
        modules={'bundle':types.SimpleNamespace(snapshot=snapshot),'artifacts':object()}
        archive=types.SimpleNamespace(write_json=write_json,archive_sources=archive_sources,
            load_archived_runtime=lambda *_:modules,verify_archive=lambda *_:None)
        archive_spec=types.SimpleNamespace(loader=types.SimpleNamespace(exec_module=lambda _:None))
        reference_spec=types.SimpleNamespace(loader=types.SimpleNamespace(exec_module=lambda _:None))
        reference=Reference()
        def get_spec(name,path):return archive_spec if name=='tiny_check_archive' else reference_spec
        def make_module(spec):return archive if spec is archive_spec else reference
        class Process:
            pid=12345
            def __init__(self,command,**kwargs):
                calls.append('fake-native');kwargs['stdout'].write(b'{"fake":true}\n');kwargs['stderr'].write(stderr)
            def poll(self):return 0
            def wait(self,timeout=None):return 0
        args=['driver','--output',str(self.out),'--expected-native-sha256',hashlib.sha256(native).hexdigest(),'--workload','legacy']
        if reuse:args+=['--reuse-bundle',str(self.old),'--expected-bundle-manifest-sha256','d'*64]
        with ExitStack() as stack:
            for obj,name,value in [(entry,'REPO',self.repo),(entry,'sample',lambda *_:dict(actualFreeBytes=2*1024**3,pressureLevel=1,reportedSwapBytes='0')),
                (entry,'read_command',lambda _:''),(entry,'owned_group',lambda _:[]),
                (entry.importlib.util,'spec_from_file_location',get_spec),(entry.importlib.util,'module_from_spec',make_module),
                (entry.subprocess,'Popen',Process),(sys,'argv',args)]:stack.enter_context(patch.object(obj,name,value))
            with redirect_stdout(io.StringIO()):code=entry.main()
        return code,json.loads((self.out/'receipt.json').read_text())

    def test_reuse_skips_copy_and_rechecks(self):
        code,r=self.invoke();self.assertEqual(code,0);self.assertEqual(r['status'],'completed')
        self.assertNotIn('snapshot',self.calls);self.assertEqual(self.calls.count('reference-check'),2)
        self.assertFalse(r['bundleCopiedForThisRun']);self.assertTrue(r['bundleReferenceUnchangedAfterRun'])

    def test_default_snapshot_unchanged(self):
        code,r=self.invoke(reuse=False);self.assertEqual(code,0)
        self.assertIn('snapshot',self.calls);self.assertNotIn('reference-create',self.calls)
        self.assertNotIn('bundleReference',r)

    def test_normal_diagnostic_still_parent_failure(self):
        self.assertEqual(len(DIAGNOSTIC),57)
        code,r=self.invoke(stderr=DIAGNOSTIC);self.assertEqual(code,1)
        self.assertEqual(r['nativeExitCode'],0);self.assertTrue(r['nativeReaped'])
        self.assertEqual(r['primaryFailure'],'ValueError: Successful native check emitted stderr')
        self.assertEqual(r['stderr.log']['sizeBytes'],57)

    def test_reference_postfailure_preserves_stderr_primary(self):
        code,r=self.invoke(stderr=DIAGNOSTIC,post_failure=True);self.assertEqual(code,1)
        self.assertIn('emitted stderr',r['primaryFailure'])
        self.assertIn('bundle_reference_recheck',r['postRunErrors'][0])

    def test_unpaired_flags_stop_before_io(self):
        args=['driver','--output',str(self.out),'--expected-native-sha256','0'*64,'--workload','legacy','--reuse-bundle',str(self.old)]
        with patch.object(sys,'argv',args),self.assertRaisesRegex(ValueError,'requires both'):entry.main()
        self.assertFalse(self.out.exists())


if __name__=='__main__':unittest.main()
