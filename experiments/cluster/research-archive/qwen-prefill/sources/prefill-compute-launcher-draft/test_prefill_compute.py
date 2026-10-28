"""Pure/fake single-process tests; actual process/socket creation is forbidden."""
import contextlib
import copy
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import uuid
import launch_prefill_compute as launcher
from prefill_compute_contract import configuration,parse,validate_first,validate_final,Records
from prefill_compute_inputs import ARTIFACT,CONFIGURATION,VOCABULARY,expected_frames,recorded_fingerprint
from prefill_compute_memory import initial_free_screen,vm_pages,MemoryGate
from prefill_compute_supervision import supervise

PROMPT=[3]*65
REQUEST_ID=str(uuid.UUID(hex='a'*32))


def fixture():
    request=dict(request=dict(requestID=REQUEST_ID,promptCount=65,chunkSize=32,outputCount=1),
        vocabularySize=VOCABULARY,promptTokenIDs=PROMPT,teacherTokenIDs=[],
        fingerprint=recorded_fingerprint(REQUEST_ID,PROMPT),
        steps=[dict(frame=f,tokenIDs=PROMPT[f['tokenOffset']:f['tokenOffset']+f['tokenCount']])for f in expected_frames()])
    first=dict(kind='qwen_layer_stage_baseline_checkpoint',baselineModelReleasedBeforeStageLoading=True,
        baseline=dict(kind='qwen_layer_stage_recorded_baseline',correctnessOnly=True,
            throughputMeasurementValid=False,allRequestStateRetired=True,request=request,
            source=dict(artifactAggregateSHA256=ARTIFACT,sourceConfigurationSHA256=CONFIGURATION)))
    final=dict(kind='qwen_layer_stage_prefill_report',schemaVersion=1,correctnessOnly=True,
        throughputMeasurementValid=False,baselineModelReleasedBeforeStageLoading=True,
        stageModelsReleasedAfterComparison=True,comparison=dict(nativeOwnerOpaquePayload=True))
    return first,final


def vm(free,inactive,speculative=0):
    return 'Mach Virtual Memory Statistics: (page size of 16384 bytes)\n'+''.join(
        f'{name}: {value*65536}.\n'for name,value in [('Pages free',free),('Pages inactive',inactive),('Pages speculative',speculative)])


class Child:
    pid=7001
    def __init__(self,code):self.code=code;self.waits=0
    def poll(self):return self.code
    def wait(self,timeout):
        assert self.code is not None
        self.waits+=1;return self.code


class Tests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup)
        self.path=Path(self.temp.name)
        for name in ('subprocess.run','subprocess.Popen','socket.socket'):
            guard=patch(name,side_effect=AssertionError('No real process/socket calls'))
            guard.start();self.addCleanup(guard.stop)
    def test_exact_single_process_argv_has_no_teacher_epoch_or_transport(self):
        c=configuration('/b','b'*64,'/m',PROMPT,180)
        self.assertEqual(c['arguments'][:2],['--mode','qwen-layer-stage-prefill-check'])
        self.assertEqual(c['environment'],{'DARKBLOOM_BF16_WEIGHTS':'1'})
        self.assertEqual(c['environment_files'],{})
        self.assertEqual(set(c['input_files']),{'prompt.json'})
        for flag in ('--teacher-tokens-file','--epoch','--transport','--synthetic'):
            self.assertNotIn(flag,c['arguments'])
        self.assertEqual(c['arguments'][c['arguments'].index('--decode-tokens')+1],'1')
    def test_timeout_and_token_bounds(self):
        for seconds in (0,181,True):
            with self.assertRaises(ValueError):configuration('/b','b'*64,'/m',PROMPT,seconds)
        with self.assertRaises(ValueError):configuration('/b','b'*64,'/m',[True]*65,180)
    def test_outer_pair_accepts_opaque_native_comparison(self):
        first,final=fixture();validate_first(first,PROMPT);validate_final(final,first)
    def test_source_history_and_recorded_fingerprint_fail_closed(self):
        for mutate in (lambda x:x['baseline']['source'].update(artifactAggregateSHA256='c'*64),
                       lambda x:x['baseline']['request'].update(teacherTokenIDs=[3]),
                       lambda x:x['baseline']['request'].update(fingerprint='c'*64)):
            first,_=fixture();mutate(first)
            with self.assertRaises(ValueError):validate_first(first,PROMPT)
    def test_release_schema_and_throughput_flags_are_required(self):
        for key,value in [('schemaVersion',True),('schemaVersion',2),('correctnessOnly',False),
                          ('throughputMeasurementValid',True),('baselineModelReleasedBeforeStageLoading',False),
                          ('stageModelsReleasedAfterComparison',False),('comparison',True)]:
            first,final=fixture();final[key]=value
            with self.assertRaises(ValueError):validate_final(final,first)
    def test_optional_outer_request_must_match_baseline(self):
        first,final=fixture();final['request']=copy.deepcopy(first['baseline']['request'])
        validate_final(final,first);final['request']['request']['outputCount']=4
        with self.assertRaises(ValueError):validate_final(final,first)
    def test_initial_free_is_not_reclaimable_and_has_timestamp(self):
        rejected=initial_free_screen(lambda:vm(5,20))
        self.assertFalse(rejected['passed']);self.assertEqual(rejected['actual_free_bytes'],5*1024**3)
        accepted=initial_free_screen(lambda:vm(6,2))
        self.assertTrue(accepted['passed']);self.assertIn('timestamp_utc',accepted)
        self.assertFalse(accepted['guarantees_six_gib_free_at_native_launch'])
        free,reclaimable=vm_pages(vm(3,9))
        self.assertEqual(free,3*1024**3);self.assertEqual(reclaimable,12*1024**3)
    def test_initial_refusal_precedes_snapshot_and_artifact_reads(self):
        runtime=self.path/'repo/experiments/cluster/runtime';runtime.mkdir(parents=True)
        model=self.path/'model';model.mkdir();output=self.path/'output'
        args=['--release',str(self.path/'missing-release'),'--runtime',str(runtime),'--model-dir',str(model),
            '--output',str(output),'--input-origin',str(self.path/'unread-origin'),
            '--expected-inventory',str(self.path/'unread-inventory'),'--artifact-aggregate-sha256',ARTIFACT,
            '--expected-native-sha256','b'*64]
        with patch.object(launcher,'initial_free_screen',return_value=dict(passed=False)), \
             patch.object(launcher,'archive_launcher',side_effect=AssertionError('Snapshot preceded free screen')) as archive, \
             contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(launcher.main(args),1);archive.assert_not_called()
        r=json.loads((output/'receipt.json').read_text())
        self.assertFalse(r['native_execution_attempted']);self.assertIn('Initial actual-free screen refused',r['error'])
    def test_json_signed_zero_duplicates_and_nonfinite(self):
        self.assertEqual(__import__('math').copysign(1,parse('[-0]')[0]),-1)
        for raw in ('{"x":1,"x":2}','[NaN]','[1e999]'):
            with self.assertRaises(ValueError):parse(raw)
    def run_fake(self,code,rows,memory=lambda:None):
        child=Child(code);clock=[0];stops=[]
        rank=dict(rank=0,local=str(self.path),directory=str(self.path),host=None)
        def start(_):
            (self.path/'stdout.jsonl').write_text(''.join(json.dumps(x)+'\n'for x in rows));return child
        def stop(_ranks,children):
            self.assertEqual(len(children),1);stops.append(True);child.code=-15
        def sleep(seconds):clock[0]+=seconds
        r=supervise(rank,PROMPT,1,start,stop,memory,lambda:clock[0],sleep)
        return r,child,stops
    def test_fast_exit_drains_both_records_and_reaps_one(self):
        r,child,stops=self.run_fake(0,fixture())
        self.assertTrue(r['passed']);self.assertFalse(stops);self.assertEqual(child.waits,1)
        self.assertFalse(r['independent_comparison_oracle_run'])
    def test_deadline_stops_single_owned_group(self):
        r,child,stops=self.run_fake(None,[fixture()[0]])
        self.assertEqual(r['cancellation_reason'],'deadline');self.assertTrue(stops);self.assertEqual(child.waits,1)
    def test_native_failure_status_is_preserved(self):
        r,child,stops=self.run_fake(7,[])
        self.assertFalse(r['passed']);self.assertEqual(r['exit_code'],7);self.assertEqual(child.waits,1)
    def test_memory_failure_stops_single_owned_group(self):
        def failed():raise ValueError('new swap')
        r,child,stops=self.run_fake(None,[],failed)
        self.assertFalse(r['passed']);self.assertTrue(stops);self.assertEqual(child.waits,1)
    def test_wrong_first_record_stops_running_native(self):
        r,child,stops=self.run_fake(None,[fixture()[1]])
        self.assertFalse(r['passed']);self.assertTrue(stops);self.assertEqual(child.waits,1)
    def test_eof_without_final_report_fails(self):
        r,child,stops=self.run_fake(0,[fixture()[0]])
        self.assertFalse(r['passed']);self.assertIn('EOF without both',r['error']);self.assertEqual(child.waits,1)
    def test_report_count_is_bounded(self):
        first,final=fixture();r,_,_=self.run_fake(0,[first,final,final])
        self.assertFalse(r['passed']);self.assertIn('record size/count',r['error'])


if __name__=='__main__':unittest.main()
