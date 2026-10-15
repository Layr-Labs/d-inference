"""Fabricated streams/processes only; subprocess and socket calls are forbidden."""
import copy
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
from readiness_config import configuration, parent_seconds
from readiness_contract import (ARTIFACT_SHA, CONFIG_SHA, PROFILE, PROFILE_SHA,
    canonical, entries, sha, validate_record, validate_pair)
from readiness_memory import Observations, parse_resources
from readiness_stream import Streams, WARNING, MISMATCH, LIMIT, strict_json
from readiness_supervision import supervise

EPOCH = '0123456789abcdef0123456789abcdef'


def record(rank=0):
    descriptor = dict(schemaVersion=1, kind='qwen_long_prefill_resident_cohort_agreement',
        initialEpoch=EPOCH, sourceConfigurationSHA256=CONFIG_SHA,
        expectedArtifactAggregateSHA256=ARTIFACT_SHA, profile=PROFILE, profileFingerprint=PROFILE_SHA,
        schedulingPolicy='serial_v1', logitsDType='bfloat16', transport='loopback-test',
        executionPath='cbv2-contiguous', requestCount=3, warmupCount=1, tracePathsDisabled=True,
        planFingerprint='a'*64, arithmeticEnvironmentSHA256='b'*64, resourceAdmissionSHA256='c'*64,
        requests=entries(EPOCH))
    fingerprint = sha(b'qwen-long-prefill-resident-cohort-v1|' + canonical(descriptor))
    return dict(kind='qwen_long_prefill_cohort_readiness_check', schemaVersion=1,
        epoch=EPOCH, fixtureCase='match', rank=rank, worldSize=2, transport='loopback-test',
        postAgreementMarker='reached_without_model_load', readinessExchangePassed=True,
        modelConstructed=False, weightsMaterialized=False, requestsExecuted=False,
        modelPayloadRead=False, requestStateCreated=False, arithmeticEnvironmentIsFixture=True,
        actualArtifactVerificationPerformed=False, actualOSResourceAdmissionPerformed=False,
        residentReuseQualified=False, physicalTransferQualified=False, throughputMeasurementValid=False,
        cohortAgreement=descriptor, cohortReadiness=dict(cohortAgreementFingerprint=fingerprint,
            readinessMaterialSHA256=sha(('qwen-long-prefill-resident-cohort-readiness-v1|' + fingerprint).encode())))


class FakeProcess:
    def __init__(self, pid, code=None):
        self.pid, self.code, self.waits = pid, code, 0
    def poll(self): return self.code
    def wait(self, timeout=0):
        if self.code is None: raise RuntimeError('fake still running')
        self.waits += 1
        return self.code


class Tests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.path = Path(self.tmp.name)
        self.guards = [patch('subprocess.run', side_effect=AssertionError('real subprocess forbidden')),
                       patch('subprocess.Popen', side_effect=AssertionError('real native forbidden')),
                       patch('socket.socket', side_effect=AssertionError('real sockets forbidden'))]
        for guard in self.guards:
            guard.start(); self.addCleanup(guard.stop)

    def cohort(self, scenario='match', failure=None, memory=None, cleanup_failure=False):
        ranks=[]; children=[]; now=[0.0]; calls=[]
        for rank in range(2):
            path=self.path/('rank-'+str(rank));path.mkdir()
            ranks.append(dict(rank=rank, host=None, local=str(path), directory=str(path), bundle=str(self.path/'bundle')))
        def start(rank):
            i=rank['rank']; p=Path(rank['local'])
            err=WARNING + (MISMATCH if scenario=='warmup-mismatch' else b'')
            (p/'stderr.log').write_bytes(err)
            stdout=canonical(record(i))+b'\n' if scenario=='match' else b''
            if failure=='invalid-output':stdout=b'broken\n'
            (p/'stdout.jsonl').write_bytes(stdout)
            code=0 if scenario=='match' else 1 if scenario=='warmup-mismatch' else None
            if failure=='early-failure':code=1
            if failure=='late-mismatch' and i==1:now[0]=parent_seconds(scenario)+.1
            if failure=='late-unexpected':code=2;now[0]=parent_seconds(scenario)+.1
            child=FakeProcess(100+i,code);children.append(child);return child
        def stop(_ranks, values):
            calls.append('stop')
            if cleanup_failure:raise RuntimeError('injected cleanup failure')
            for child in values:
                if child.code is None:child.code=143
        def sleep(seconds):now[0]+=seconds
        def observe(deadline):
            if memory=='past-deadline':now[0]=deadline+0.1
            if memory=='exit-past-deadline':
                children[0].code=1;now[0]=deadline+.1
            if memory=='pressure':raise ValueError('injected pressure')
        def validate(streams):
            result=validate_pair(streams)
            if failure=='slow-success-validation':now[0]=parent_seconds(scenario)+.1
            return result
        with patch('readiness_supervision.validate_pair',side_effect=validate):
            result=supervise(ranks,EPOCH,scenario,start,stop,memory=observe,
                clock=lambda:now[0],sleep=sleep)
        return result,children,calls

    def test_exact_configuration_no_model_or_reencoding(self):
        c=configuration('/new/bundle','d'*64,1,EPOCH,'match',[['127.0.0.1:12001'],['127.0.0.1:12002']])
        self.assertEqual(len(c['arguments']),10)
        self.assertEqual(c['input_files'],{})
        self.assertNotIn('model_directory',c)
        self.assertEqual(c['timeout_seconds'],30)
        self.assertEqual(c['environment']['MLX_RANK'],'1')
        self.assertEqual(c['environment_files'],{'MLX_HOSTFILE':'hosts.json'})

    def test_missing_peer_keeps_match_case(self):
        c=configuration('/b','d'*64,0,EPOCH,'missing-peer',[['127.0.0.1:1'],['127.0.0.1:2']])
        self.assertEqual(c['arguments'][7],'match');self.assertEqual(parent_seconds('missing-peer'),3)

    def test_configuration_refuses_invalid_identity_and_hosts(self):
        for rank,epoch,hosts in [(True,EPOCH,[['127.0.0.1:1'],['127.0.0.1:2']]),
            (0,'X'*32,[['127.0.0.1:1'],['127.0.0.1:2']]),
            (0,EPOCH,[['127.0.0.1:1'],['127.0.0.1:1']]),
            (0,EPOCH,[['0.0.0.0:1'],['127.0.0.1:2']])]:
            with self.assertRaises(ValueError):configuration('/b','d'*64,rank,epoch,'match',hosts)

    def test_real_request_recipe_fresh_A_B_A(self):
        values=entries(EPOCH)
        self.assertEqual(len({x['epoch'] for x in values}),3)
        self.assertEqual(values[0]['promptFileSHA256'],values[2]['promptFileSHA256'])
        self.assertNotEqual(values[0]['recordedRequestFingerprint'],values[2]['recordedRequestFingerprint'])
        self.assertEqual([x['excludedWarmup'] for x in values],[True,False,False])

    def test_valid_success_record(self):validate_record(record(),0,EPOCH,'match')

    def test_strict_identity_scope_and_nested_types(self):
        for key,value in [('rank',True),('schemaVersion',1.0),('weightsMaterialized',True),
                          ('modelPayloadRead',True),('throughputMeasurementValid',True)]:
            value_record=record();value_record[key]=value
            with self.assertRaises(ValueError):validate_record(value_record,0,EPOCH,'match')
        value_record=record();value_record['cohortAgreement']['requests'][0]['ordinal']=False
        with self.assertRaises(ValueError):validate_record(value_record,0,EPOCH,'match')

    def test_order_raw_pin_and_digest_replay_refused(self):
        for mutation in ['order','raw','digest']:
            r=record()
            if mutation=='order':r['cohortAgreement']['requests'].reverse()
            if mutation=='raw':r['cohortAgreement']['requests'][1]['promptFileSHA256']='0'*64
            if mutation=='digest':r['cohortReadiness']['readinessMaterialSHA256']='0'*64
            with self.assertRaises(ValueError):validate_record(r,0,EPOCH,'match')

    def test_duplicate_and_nonfinite_json(self):
        for data in ['{"x":1,"x":2}','{"x":NaN}','{"x":1e999}']:
            with self.assertRaises(ValueError):strict_json(data)

    def test_match_two_completed_reaped_supervisors(self):
        r,children,calls=self.cohort()
        self.assertTrue(r['scenario_passed']);self.assertTrue(r['native_success'])
        self.assertEqual([x.waits for x in children],[1,1]);self.assertEqual(calls,[])

    def test_expected_mismatch_is_not_native_success(self):
        r,children,calls=self.cohort('warmup-mismatch')
        self.assertTrue(r['scenario_passed']);self.assertFalse(r['native_success'])
        self.assertEqual(r['primary_reason'],'expected_warmup_mismatch')
        self.assertEqual(r['supervisor_exit_codes'],[1,1]);self.assertEqual(calls,[])
        self.assertIsNone(r['supervisor_exit_codes_before_cancellation'])

    def test_missing_peer_parent_deadline(self):
        r,children,calls=self.cohort('missing-peer')
        self.assertTrue(r['scenario_passed']);self.assertFalse(r['native_success'])
        self.assertEqual(r['primary_reason'],'parent_deadline')
        self.assertEqual(r['started_rank_count'],1);self.assertEqual(r['configured_rank_count'],2)
        self.assertEqual(r['supervisor_exit_codes_before_cancellation'],[None])
        self.assertTrue(r['missing_peer_running_observed_before_parent_cancellation'])

    def test_mismatch_first_observed_after_deadline_is_not_passed(self):
        r,_,_=self.cohort('warmup-mismatch',failure='late-mismatch')
        self.assertFalse(r['scenario_passed']);self.assertEqual(r['primary_reason'],'parent_deadline')
        self.assertEqual(r['supervisor_exit_codes_before_cancellation'],[1,1])

    def test_mismatch_validation_time_is_charged(self):
        original=Streams.negative
        ticks=[0.0]
        def negative(stream,*args,**kwargs):
            original(stream,*args,**kwargs);ticks[0]=46.0
        with patch.object(Streams,'negative',negative),patch('readiness_supervision.parent_seconds',return_value=45):
            ranks=[];children=[]
            for rank in range(2):
                path=self.path/str(rank);path.mkdir()
                (path/'stdout.jsonl').write_bytes(b'')
                (path/'stderr.log').write_bytes(WARNING+MISMATCH)
                ranks.append(dict(rank=rank,host=None,local=str(path)))
            def start(rank):
                child=FakeProcess(100+rank['rank'],1)
                children.append(child);return child
            def stop(_ranks,values):
                for child in values:
                    if child.code is None:child.code=143
            r=supervise(ranks,EPOCH,'warmup-mismatch',start,stop,clock=lambda:ticks[0])
        self.assertFalse(r['scenario_passed']);self.assertEqual(r['primary_reason'],'parent_deadline')

    def test_missing_peer_exit_during_slow_observation_is_inconclusive(self):
        r,children,_=self.cohort('missing-peer',memory='exit-past-deadline')
        self.assertFalse(r['scenario_passed']);self.assertEqual(r['primary_reason'],'parent_deadline')
        self.assertEqual(r['supervisor_exit_codes_before_cancellation'],[1])
        self.assertFalse(r['missing_peer_running_observed_before_parent_cancellation'])
        self.assertEqual(children[0].waits,1)

    def test_already_observed_unexpected_failure_keeps_priority(self):
        r,_,_=self.cohort('missing-peer',failure='late-unexpected')
        self.assertFalse(r['scenario_passed']);self.assertEqual(r['primary_reason'],'unexpected_rank_failure')

    def test_early_failure_is_not_a_missing_peer_pass(self):
        r,_,_=self.cohort('missing-peer',failure='early-failure')
        self.assertFalse(r['scenario_passed']);self.assertEqual(r['primary_reason'],'unexpected_rank_failure')

    def test_post_observation_deadline_before_success(self):
        r,_,_=self.cohort(memory='past-deadline')
        self.assertFalse(r['scenario_passed']);self.assertEqual(r['primary_reason'],'parent_deadline')

    def test_final_success_validation_time_is_charged(self):
        r,children,_=self.cohort(failure='slow-success-validation')
        self.assertFalse(r['scenario_passed']);self.assertFalse(r['native_success'])
        self.assertEqual(r['primary_reason'],'parent_deadline')
        self.assertEqual([x.waits for x in children],[1,1])

    def test_pressure_failure_retained(self):
        r,_,_=self.cohort(memory='pressure')
        self.assertFalse(r['scenario_passed']);self.assertIn('pressure',r['primary_error'])

    def test_primary_and_cleanup_errors_separate(self):
        r,_,_=self.cohort(failure='invalid-output',cleanup_failure=True)
        self.assertFalse(r['scenario_passed']);self.assertEqual(r['primary_reason'],'output_memory_or_startup_failure')
        self.assertIn('cleanup failure',r['cleanup_errors'][0]['error'])
        self.assertNotIn('cleanup failure',r['primary_error'])

    def test_stream_extra_line_warning_and_bound(self):
        stream=Streams(self.path,0,EPOCH,'match',validate_record)
        (self.path/'stdout.jsonl').write_bytes(canonical(record())+b'\n\n')
        (self.path/'stderr.log').write_bytes(WARNING)
        with self.assertRaises(ValueError):stream.poll()
        (self.path/'stdout.jsonl').write_bytes(b'x'*(LIMIT+1))
        with self.assertRaises(ValueError):Streams(self.path,0,EPOCH,'match',validate_record).poll()
        (self.path/'stdout.jsonl').write_bytes(b'')
        (self.path/'stderr.log').write_bytes(WARNING+b'extra\n')
        with self.assertRaises(ValueError):Streams(self.path,0,EPOCH,'match',validate_record).poll()

    def test_tiny_resource_units_and_no_new_swap(self):
        memory='2\ntotal = 10.00M used = 2.00M free = 8.00M\n'
        vm='Mach Virtual Memory Statistics: (page size of 16384 bytes)\nPages free: 65536.\n'
        value=parse_resources(memory,vm)
        self.assertEqual(value['actual_free_bytes'],1024**3)
        self.assertEqual(value['reported_swap_bytes'],'2097152.00')
        def read(args,timeout=3):
            return memory if 'sysctl' in args[0] else vm if 'vm_stat' in args[0] else ''
        obs=Observations(self.path,read=read)
        obs.observe(initial_free=True)
        memory='2\ntotal = 10.00M used = 2.01M free = 7.99M\n'
        with self.assertRaises(ValueError):obs.observe()

    def test_observation_charges_each_command_to_parent_budget(self):
        now=[0.0]; budgets=[]
        def read(args,timeout=3):
            budgets.append(timeout);now[0]+=.3
            return ('1\ntotal = 1M used = 0M free = 1M\n' if 'sysctl' in args[0] else
                    'page size of 16384 bytes\nPages free: 65536.\n')
        obs=Observations(self.path,read=read,clock=lambda:now[0])
        with self.assertRaises(TimeoutError):obs.observe(deadline=.5)
        self.assertEqual(len(budgets),2)
        self.assertAlmostEqual(budgets[0],.5);self.assertAlmostEqual(budgets[1],.2)

    def test_owned_pid_roles_rss_and_postflight(self):
        ps=[f'100 10 100 20 python {self.path}/rank-0/rank.json\n'
            f'200 100 200 30 {self.path}/bundle/cluster-inference --mode test\n']
        def read(args,timeout=3):
            if 'sysctl' in args[0]:return '1\ntotal = 1M used = 0M free = 1M\n'
            if 'vm_stat' in args[0]:return 'page size of 16384 bytes\nPages free: 65536.\n'
            return ps[0]
        obs=Observations(self.path,read=read)
        obs.started(dict(host=None,rank=0),FakeProcess(100))
        sample=obs.observe()
        self.assertEqual([x['role'] for x in sample['owned_processes']],['supervisor','native'])
        self.assertEqual(sample['owned_processes'][1]['rss_bytes'],30*1024)
        self.assertEqual(len(obs.postflight()['observed_remaining']),2)
        ps[0]='';self.assertEqual(obs.postflight()['observed_remaining'],[])

    def test_fake_main_stages_both_configs_and_keeps_postflight_failure(self):
        import types
        import launch_readiness as entry
        runtime=self.path/'repo/experiments/cluster/runtime';runtime.mkdir(parents=True)
        release=self.path/'release';release.mkdir()
        native=b'fake executable, never run'
        class Memory:
            def __init__(self,*args):self.samples=[]
            def observe(self,**kwargs):self.samples.append({'fake':True})
            def started(self,*args):pass
            def postflight(self):return dict(observed_remaining=[],independent_native_waitpid=False)
        def archive_sources(_runtime,output):
            (output/'source-manifest.json').write_text('{}')
            return {'files':[]}
        def snapshot(_release,bundle):
            bundle.mkdir();(bundle/'cluster-inference').write_bytes(native)
            return 'd'*64
        def start(rank):
            directory=Path(rank['local']);index=rank['rank']
            (directory/'stdout.jsonl').write_bytes(canonical(record(index))+b'\n')
            (directory/'stderr.log').write_bytes(WARNING)
            return FakeProcess(100+index,0)
        modules=dict(bundle=types.SimpleNamespace(snapshot=snapshot),
            configuration=types.SimpleNamespace(loopback_addresses=lambda:[['127.0.0.1:1'],['127.0.0.1:2']]),
            processes=types.SimpleNamespace(start=start,stop_processes=lambda *_:None))
        calls=[]
        def verify(*args):
            calls.append(True)
            if len(calls)==2:raise ValueError('injected postflight source drift')
        arguments=types.SimpleNamespace(runtime=runtime,release=release,output=self.path/'run',
            expected_native_sha256=sha(native),scenario='match')
        with patch.object(entry,'Observations',Memory),patch.object(entry,'archive_launcher',return_value=[]),\
             patch.object(entry,'archive_sources',side_effect=archive_sources),\
             patch.object(entry,'load_archived_runtime',return_value=modules),\
             patch.object(entry,'source_contract',return_value={}),patch.object(entry,'verify_archive',side_effect=verify),\
             patch.object(entry.uuid,'uuid4',return_value=types.SimpleNamespace(hex=EPOCH)):
            result=entry.run(arguments)
        self.assertTrue(result['native_success']);self.assertFalse(result['scenario_passed'])
        self.assertEqual(result['status'],'failed');self.assertIsNone(result['primary_failure'])
        self.assertIn('source drift',result['post_run_errors'][0]['error'])
        self.assertEqual(len(result['configuration_files']),4)
        for index in range(2):
            config=json.loads((arguments.output/f'rank-{index}/rank.json').read_text())
            self.assertNotIn('model_directory',config);self.assertEqual(config['input_files'],{})


if __name__ == '__main__':unittest.main()
