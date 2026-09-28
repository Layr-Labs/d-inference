"""Fake entry wiring only; no bundle validator, processes or memory commands run."""
from contextlib import ExitStack
import hashlib
from pathlib import Path
import tempfile
import types
import unittest
from unittest.mock import patch
import launch_readiness as entry


class ReuseEntryTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup)
        self.root=Path(self.temp.name);self.runtime=self.root/'repo/experiments/cluster/runtime'
        self.runtime.mkdir(parents=True);self.release=self.root/'release';self.release.mkdir()
        self.source=self.root/'old-bundle';self.source.mkdir()
        self.native=b'invented executable bytes; never executed'
        (self.source/'cluster-inference').write_bytes(self.native)
        self.calls=[]

    def invoke(self, *, scenario='match', source_error=False, reference_error=None):
        output=self.root/('run-'+scenario)
        args=types.SimpleNamespace(runtime=self.runtime,release=self.release,output=output,
            expected_native_sha256=hashlib.sha256(self.native).hexdigest(),scenario=scenario,
            reuse_bundle=self.source,expected_bundle_manifest_sha256='d'*64)
        calls=self.calls
        class Memory:
            def __init__(self,*_):self.samples=[]
            def observe(self,**kwargs):calls.append(('memory',kwargs));self.samples.append({'fake':True})
            def started(self,*_):pass
            def postflight(self):return dict(observed_remaining=[])
        class Helper:
            checks=0
            def create_reference(self,source,destination,manifest,native,runtime,artifacts):
                calls.append(('create-reference',str(source)))
                destination.symlink_to(source,target_is_directory=True)
                return dict(manifestSHA256=manifest,copied=False,resolvedPath=str(source))
            def check_reference(self,*_):
                self.checks+=1;calls.append(('reference-check',self.checks))
                if self.checks==reference_error:raise ValueError('injected reference drift')
        def sources(_runtime,out):
            (out/'source-manifest.json').write_text('{}');return {'files':[]}
        checks=[]
        def verify(*_):
            checks.append(True)
            if source_error and len(checks)==2:raise ValueError('injected source drift')
        def supervise(*_,**kwargs):
            calls.append(('supervise',scenario))
            return dict(cleanup_errors=[],native_success=scenario=='match',scenario_passed=True)
        def forbidden_snapshot(*_):raise AssertionError('Reuse invoked bundle copy')
        modules=dict(bundle=types.SimpleNamespace(snapshot=forbidden_snapshot),artifacts=object(),
            configuration=types.SimpleNamespace(loopback_addresses=lambda:[['127.0.0.1:1'],['127.0.0.1:2']]),
            processes=types.SimpleNamespace(start=None,stop_processes=None))
        with ExitStack() as stack:
            for name,value in [('Observations',Memory),('archive_launcher',lambda _:[]),
                ('archive_sources',sources),('load_archived_runtime',lambda *_:modules),
                ('load_reference_helper',lambda:Helper()),('source_contract',lambda _:{}),
                ('verify_archive',verify),('supervise',supervise)]:
                stack.enter_context(patch.object(entry,name,value))
            result=entry.run(args)
        return result,output

    def test_reuse_records_and_checks_all_three_fake_scenarios(self):
        for scenario in ('match','warmup-mismatch','missing-peer'):
            with self.subTest(scenario=scenario):
                self.calls.clear();result,out=self.invoke(scenario=scenario)
                self.assertEqual(result['status'],'passed')
                self.assertEqual(result['native_success'],scenario=='match')
                self.assertTrue((out/'bundle').is_symlink())
                self.assertFalse(result['bundle_copied_for_this_run'])
                self.assertEqual(result['bundle_acquisition'],'reused_external_reference')
                self.assertTrue(result['bundle_reference_unchanged_after_run'])
                self.assertEqual([x for x in self.calls if x[0]=='reference-check'],[('reference-check',1),('reference-check',2)])
                self.assertLess(self.calls.index(('reference-check',1)),self.calls.index(('supervise',scenario)))

    def test_source_and_reference_postflight_failures_are_independent(self):
        result,_=self.invoke(source_error=True,reference_error=2)
        self.assertEqual(result['status'],'failed')
        operations={r['operation'] for r in result['post_run_errors']}
        self.assertEqual(operations,{'source_bundle_launcher_recheck','reused_bundle_reference_recheck'})
        self.assertNotIn('bundle_reference_unchanged_after_run',result)

    def test_reference_prelaunch_refusal_never_starts(self):
        result,_=self.invoke(reference_error=1)
        self.assertFalse(result['native_execution_attempted'])
        self.assertIn('reference drift',result['primary_failure'])
        self.assertFalse(any(x[0]=='supervise' for x in self.calls))

    def test_unpaired_flags_refuse_before_output_or_sampling(self):
        args=types.SimpleNamespace(reuse_bundle=self.source,expected_bundle_manifest_sha256=None)
        with patch.object(entry,'Observations',side_effect=AssertionError('sampled')):
            with self.assertRaisesRegex(ValueError,'requires both'):entry.run(args)


if __name__=='__main__':unittest.main()
