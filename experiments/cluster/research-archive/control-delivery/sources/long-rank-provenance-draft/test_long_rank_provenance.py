"""Prospective full fake archives; all real process/socket entrypoints blocked."""
import copy
from dataclasses import replace
import json
from pathlib import Path
import shlex
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch
from long_reference_provenance_common import files, parse, read, sha
from long_rank_fixture import make_fixture, write
from long_rank_provenance_archive import provenance, warning_source
from long_rank_provenance_records import validate_completion, validate_layout, validate_hostfile
from long_rank_provenance_resources import resources_and_controls
from long_rank_provenance_workload import workload_and_controls
from verify_long_rank_provenance import validate, validate_postflight
from postflight_remote_long_ranks import observe, main as postflight_main


class Tests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory(); self.addCleanup(temp.cleanup)
        self.root = Path(temp.name).resolve()
        for name in ('subprocess.run', 'subprocess.Popen', 'socket.socket'):
            guard = patch(name, side_effect=AssertionError('Real process/socket forbidden'))
            guard.start(); self.addCleanup(guard.stop)
        self.f = make_fixture(self.root)

    def audit(self, **changes):
        f = self.f
        args = dict(run=f.run, receipt_sha=sha(f.run / 'receipt.json'), pins=f.pins, policy=f.policy,
            review_path=f.review, review_sha=f.review_sha, origin_directory=f.origin,
            postflight_path=f.postflight, postflight_sha=sha(f.postflight))
        args.update(changes)
        return validate(**args)

    def test_complete_fake_serial_archive_and_opaque_streams_pass(self):
        result = self.audit()
        self.assertEqual(result['status'], 'passed'); self.assertFalse(result['liveRepositoryCompared'])
        self.assertEqual(result['resources']['sourceBoundNativeProcessesObserved'], 2)
        self.assertEqual(result['resources']['maximumSimultaneouslyObservedNativeRSSBytes'], 12288)
        self.assertTrue(all(not row['nativeOutputJSONParsed'] for row in result['workload']['rankStreams']))
        self.assertFalse(result['nativeWireActionTimingOracleRun'])

    def test_complete_fake_lookahead_archive_and_explicit_policy_binding(self):
        other = self.root / 'other'; other.mkdir(); self.f = make_fixture(other, 'prompt_lookahead_one_v1')
        self.assertEqual(self.audit()['policy'], 'prompt_lookahead_one_v1')
        with self.assertRaises(ValueError): self.audit(policy='serial_v1')

    def test_all_external_pins_and_old_launcher_namespace_refuse(self):
        for key in ('native', 'prompt', 'origin', 'configuration', 'artifact'):
            with self.subTest(key=key), self.assertRaises(ValueError):
                self.audit(pins=replace(self.f.pins, **{key: '0' * 64}))
        for key in ('receipt_sha', 'review_sha', 'postflight_sha'):
            with self.subTest(key=key), self.assertRaises(ValueError): self.audit(**{key: '0' * 64})
        receipt = read(self.f.run / 'receipt.json')
        for key, value in [('kind','remote_qwen_layer_stage_prefill_rank_launcher'), ('envelope_version',3),
                           ('flow','bounded_prefill_measurement_v1'), ('native_timeout_seconds',180),
                           ('parent_timeout_seconds',331), ('timing_diagnostic_only',False),
                           ('cleanup_errors',['failed']), ('primary_failure',{'failed':True})]:
            with self.subTest(key=key), self.assertRaises(ValueError):
                validate_completion(dict(receipt, **{key:value}), self.f.pins, self.f.policy)

    def test_unique_cohort_paths_local_ssh_pids_and_typed_completion_refuse(self):
        original = read(self.f.run / 'receipt.json')
        for key, value in [('local_ssh_client_pids',[77,77]), ('exit_codes',[False,0]),
                           ('local_ssh_clients_reaped',[1,True]), ('remote_process_reaping_independently_verified',True)]:
            receipt = copy.deepcopy(original); receipt['cohort'][key] = value
            with self.subTest(key=key), self.assertRaises(ValueError): validate_completion(receipt,self.f.pins,self.f.policy)
        for change in ('duplicate', 'escape', 'model', 'epoch', 'host'):
            receipt = copy.deepcopy(original)
            if change=='duplicate': receipt['remote_paths']['rank_directories'][1]=receipt['remote_paths']['rank_directories'][0]
            if change=='escape': receipt['remote_paths']['run']='/owned/../bad'
            if change=='model': receipt['remote_paths']['model']='/owned/model'
            if change=='epoch': receipt['epoch']='4'*32
            if change=='host': receipt['execution_host']='-oUnsafe'
            with self.subTest(change=change), self.assertRaises(ValueError): validate_layout(receipt)

    def test_exact_loopback_endpoint_and_rank_command_contract(self):
        for endpoints in [[['0.0.0.0:1000'],['127.0.0.1:1001']], [['127.0.0.1:01000'],['127.0.0.1:1001']],
                          [['127.0.0.1:1000'],['127.0.0.1:1000']]]:
            with self.assertRaises(ValueError): validate_hostfile(endpoints)
        receipt=read(self.f.run/'receipt.json'); path=self.f.run/'rank-1/rank.json'; original=read(path)
        for change in ('mode','environment','rewrite','rank'):
            rank=copy.deepcopy(original)
            if change=='mode': rank['arguments'][1]='qwen-layer-stage-prefill-rank-check'
            if change=='environment': rank['environment']['MLX_RANK']='0'
            if change=='rewrite': rank['input_files']={'prompt.json':[3]*8192}
            if change=='rank': rank['rank']=0
            write(path,rank); write(self.f.run/'remote-metadata/rank-1-rank.json',rank)
            receipt['rank_configuration_sha256'][1]=sha(path)
            with self.subTest(change=change), self.assertRaisesRegex(ValueError,'Exact rank configuration differs'):
                workload_and_controls(self.f.run,receipt,self.f.pins,{},self.f.origin)

    def test_source_bundle_launcher_control_and_raw_prompt_drift_refuse(self):
        for name in ('source/experiments/cluster/runtime/rank_worker.py','bundle/cluster-inference',
                     'launcher/long_rank_control.py','controls/control-config.json','rank-1/prompt.json',
                     'remote-metadata/rank-0-prompt.json','remote-metadata/rank-1-hosts.json'):
            path=self.f.run/name; original=path.read_bytes();path.write_bytes(original+b' ')
            with self.subTest(path=name), self.assertRaises(ValueError):self.audit()
            path.write_bytes(original)

    def test_exact_warning_empty_duplicate_changed_bytes_and_logger_refuse(self):
        path=self.f.run/'rank-0/stderr.log'; original=path.read_bytes()
        for value in (b'',original+original,original.replace(b'correctness',b'performance')):
            path.write_bytes(value)
            with self.assertRaises(ValueError):self.audit()
        path.write_bytes(original)
        source=self.f.run/'source/experiments/cluster/inference/Sources/ClusterInference/Options.swift'
        source.write_text('func log(_ message: String) { print(message) }')
        with self.assertRaises(ValueError):warning_source(self.f.run,read(self.f.run/'receipt.json'))

    def test_unsafe_archive_paths_symlinks_duplicate_keys_and_oversized_stream_refuse(self):
        outside=self.root/'outside';outside.write_bytes(b'x')
        for name in ('../outside','/outside'):
            with self.assertRaises(ValueError):files(self.f.run,[dict(path=name,size_bytes=1,sha256=sha(outside))])
        link=self.f.run/'link';link.symlink_to(outside)
        with self.assertRaises(ValueError):files(self.f.run,[dict(path='link',size_bytes=1,sha256=sha(outside))])
        for value in ('{"x":1,"x":2}','{"x":1,"\\u0078":2}','[NaN]','[1e999]'):
            with self.assertRaises(ValueError):parse(value)
        with (self.f.run/'rank-0/stdout.jsonl').open('wb') as stream:stream.truncate(8*1024**2+1)
        with self.assertRaises(ValueError):self.audit()

    def test_cross_rank_pid_attribution_missing_owner_and_parent_mutations_refuse(self):
        original=read(self.f.run/'receipt.json')
        for change in ('duplicate','wrong_path','missing','unknown_rank','parent','rss'):
            receipt=copy.deepcopy(original);rows=receipt['remote_memory_samples'][1]['remote_pid_inventory']['observed_processes']
            if change=='duplicate': rows[2]['pid']=rows[0]['pid']
            if change=='wrong_path': rows[2]['command']=rows[0]['command']
            if change=='missing': rows.pop(2)
            if change=='unknown_rank': rows[0]['rank']=2
            if change=='parent': rows[0]['ppid']=rows[3]['pid']
            if change=='rss': rows[0]['rssBytes']=1
            with self.subTest(change=change), self.assertRaises(ValueError):
                resources_and_controls(self.f.run,receipt,read,sha)

    def test_resource_and_replayed_control_changes_refuse(self):
        original=read(self.f.run/'receipt.json')
        for change in ('free','reclaim','swap','pressure'):
            receipt=copy.deepcopy(original)
            if change=='free': receipt['remote_initial_free_screen']['actual_free_bytes']+=1
            if change=='reclaim': receipt['remote_before']['posthash_preflight']['estimated_reclaimable_bytes']+=1
            if change=='swap':
                for sample in receipt['remote_memory_samples']: sample.update(swap_used_bytes='1048576',raw_sysctl='1\nused = 1.00M\n')
            if change=='pressure':receipt['remote_memory_samples'][1].update(pressure_level=3,raw_sysctl='3\nused = 0.00M\n')
            with self.subTest(change=change), self.assertRaises(ValueError):resources_and_controls(self.f.run,receipt,read,sha)
        path=self.f.run/'remote-observations/0003-observe.json';value=read(path);value['record']['run_id']='4'*32;write(path,value)
        with self.assertRaises(ValueError):self.audit()

    def test_raw_origin_source_and_remote_before_attestation_refuse(self):
        path=self.f.origin/'source-text.txt';path.write_bytes(b'changed')
        with self.assertRaises(ValueError):self.audit()
        path.write_bytes(b'prose')
        receipt=read(self.f.run/'receipt.json');receipt['remote_before']['ranks'][1]['raw_prompt_reencoded']=True
        with self.assertRaisesRegex(ValueError,'Remote raw rank verification differs'):
            bundle={x['path']:x['sha256'] for x in read(self.f.run/'bundle/bundle.json')['files']}
            workload_and_controls(self.f.run,receipt,self.f.pins,bundle,self.f.origin)

    def test_postflight_fake_invocation_quoting_timeout_and_refusal(self):
        receipt=read(self.f.run/'receipt.json');calls=[]
        def invoke(arguments,**kwargs):
            calls.append((arguments,kwargs))
            return SimpleNamespace(returncode=0,stderr='',stdout=json.dumps(dict(remoteRun=receipt['remote_paths']['run'],ownedLiveProcesses=[])))
        self.assertTrue(observe(receipt,invoke)['passed'])
        argv=shlex.split(calls[0][0][-1]);self.assertEqual(argv[:2],['/usr/bin/python3','-c'])
        self.assertEqual(json.loads(argv[3]),receipt['remote_paths']);self.assertEqual(calls[0][1]['timeout'],20)
        with self.assertRaises(ValueError):postflight_main([str(self.f.run),'--receipt-sha256','0'*64,
            '--expected-native-sha256',self.f.pins.native,'--policy','serial_v1','--root-launcher-exit-code','0',
            '--output',str(self.root/'never.json')],invoke=lambda *a,**k:self.fail('Invoked'))

    def test_postflight_owned_process_source_pin_policy_and_scope_refuse(self):
        receipt=read(self.f.run/'receipt.json');record=read(self.f.postflight)
        for key,value in [('nativeBinarySHA256','0'*64),('policy','prompt_lookahead_one_v1'),
                          ('liveRepositoryCompared',True),('remoteReapingIndependentlyProven',True),('sshExitCode',False),
                          ('localSSHClientPIDs',[77,77])]:
            with self.subTest(key=key),self.assertRaises(ValueError):
                validate_postflight(dict(record,**{key:value}),receipt,sha(self.f.run/'receipt.json'),self.f.pins,self.f.policy,self.f.run)
        for code,rows,stderr in [(0,[dict(pid=1)],''),(255,[],''),(0,[],'warning')]:
            def invoke(*args,**kwargs):return SimpleNamespace(returncode=code,stderr=stderr,stdout=json.dumps(dict(
                remoteRun=receipt['remote_paths']['run'],ownedLiveProcesses=rows)))
            self.assertFalse(observe(receipt,invoke)['passed'])


if __name__=='__main__':unittest.main()
