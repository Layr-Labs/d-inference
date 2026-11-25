"""CPU fixtures only; native processes, system queries and sockets are forbidden."""
import copy
import json
import math
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import uuid

from stage_rank_contract import rank_configuration,validate_record,validate_pair,RankRecords,strict_json
from stage_rank_inputs import ARTIFACT,CONFIGURATION,VOCABULARY,expected_frames,request_fingerprint
from stage_rank_supervision import supervise

EPOCH='a'*32
INPUTS=dict(prompt=[3]*65,teacher=[4087,13,271])


def fixture(rank):
    common=dict(schemaVersion=1,epoch=EPOCH,rank=rank,worldSize=2,transport='loopback-test',backend='ring')
    ready=dict(kind='qwen_layer_stage_rank_ready',**common)
    frames=[]
    for frame in expected_frames():
        frames.append(dict(kind='qwen_layer_stage_rank_frame_completion',headerSHA256='e'*64,
            completedTransportPhase='consumed_ack_received_and_validated' if rank==0 else 'consumed_ack_send_completed',
            capture=dict(kind='qwen_layer_stage_rank_frame_capture',frame=frame,
                committedTokens=frame['tokenOffset']+frame['tokenCount'],boundaryPayloadSHA256='f'*64,
                identity=dict(stageIndex=rank,requestFingerprint=request_fingerprint(EPOCH),
                    artifactAggregateSHA256=ARTIFACT,sourceConfigurationSHA256=CONFIGURATION,
                    storageCommitmentSHA256='c'*64,planFingerprint='d'*64,
                    bf16ConversionEnabled=True,activationDType='bfloat16'))))
    terminal=dict(kind='qwen_layer_stage_rank_report',completed=True,correctnessOnly=True,
        throughputMeasurementValid=False,modelForwardCompared=False,allRequestStateRetired=True,modelReleased=True,
        sourceLoad=dict(stageIndex=rank,verifiedAggregateSHA256=ARTIFACT,sourceConfigurationSHA256=CONFIGURATION,
                        planSHA256='d'*64,storageCommitmentSHA256='c'*64),
        request=dict(request=dict(requestID=str(uuid.UUID(hex=EPOCH)),promptCount=65,chunkSize=32,outputCount=4),
                     vocabularySize=VOCABULARY,promptTokenIDs=INPUTS['prompt'],teacherTokenIDs=INPUTS['teacher']),
        frames=frames,**common)
    return ready,terminal


class Process:
    def __init__(self,pid,code):self.pid,self.code,self.waited=pid,code,False
    def poll(self):return self.code
    def wait(self,timeout=None):
        if self.code is None:raise AssertionError('Unbounded fake wait')
        self.waited=True;return self.code


class Tests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup)
        self.root=Path(self.temp.name);self.ranks=[]
        for rank in range(2):
            path=self.root/str(rank);path.mkdir()
            self.ranks.append(dict(rank=rank,local=str(path),directory=str(path),host=None,inputs=INPUTS))
        for target in ('subprocess.run','subprocess.Popen','socket.socket'):
            guard=patch(target,side_effect=AssertionError('No native/system/socket call in CPU test'))
            guard.start();self.addCleanup(guard.stop)
    def write(self,rank,rows):
        (Path(self.ranks[rank]['local'])/'stdout.jsonl').write_text(''.join(json.dumps(r)+'\n' for r in rows))
    def test_native_argv_and_model_pin(self):
        config=rank_configuration('/bundle','b'*64,0,EPOCH,180,[['127.0.0.1:20001'],['127.0.0.1:20002']],'/model',**dict(prompt=INPUTS['prompt'],teacher=INPUTS['teacher']))
        self.assertEqual(config['artifact_aggregate_sha256'],ARTIFACT)
        self.assertNotIn('--synthetic',config['arguments'])
        self.assertEqual(config['environment']['DARKBLOOM_BF16_WEIGHTS'],'1')
        self.assertEqual(config['arguments'][:2],['--mode','qwen-layer-stage-rank-check'])
        self.assertIn('--execution-path',config['arguments'])
    def test_timeout_bound(self):
        for timeout in [0,181,True]:
            with self.assertRaises(ValueError):rank_configuration('/b','b'*64,0,EPOCH,timeout,[['127.0.0.1:1'],['127.0.0.1:2']],'/m',INPUTS['prompt'],INPUTS['teacher'])
    def test_ready_and_completed(self):
        for rank in [0,1]:
            for row in fixture(rank):validate_record(row,rank,EPOCH,INPUTS)
    def test_wrong_pin_rejected(self):
        row=fixture(0)[1];row['sourceLoad']['verifiedAggregateSHA256']='b'*64
        with self.assertRaises(ValueError):validate_record(row,0,EPOCH,INPUTS)
    def test_wrong_teacher_rejected(self):
        row=fixture(0)[1];row['request']=copy.deepcopy(row['request']);row['request']['teacherTokenIDs'][0]=9
        with self.assertRaises(ValueError):validate_record(row,0,EPOCH,INPUTS)
    def test_missing_frame_and_wrong_phase_rejected(self):
        row=fixture(0)[1];row['frames'].pop()
        with self.assertRaises(ValueError):validate_record(row,0,EPOCH,INPUTS)
        row=fixture(0)[1];row['frames'][2]['completedTransportPhase']='sent'
        with self.assertRaises(ValueError):validate_record(row,0,EPOCH,INPUTS)
    def test_bool_frame_integer_rejected(self):
        row=fixture(0)[1];row['frames'][0]['capture']['frame']['sequence']=False
        with self.assertRaises(ValueError):validate_record(row,0,EPOCH,INPUTS)
    def test_no_release_or_false_baseline_claim(self):
        for key,value in [('modelReleased',False),('allRequestStateRetired',False),('modelForwardCompared',True)]:
            row=fixture(0)[1];row[key]=value
            with self.assertRaises(ValueError):validate_record(row,0,EPOCH,INPUTS)
    def test_signed_zero_is_retained(self):
        parsed=strict_json('{"values":[-0,-0.0,0]}')['values']
        self.assertEqual([math.copysign(1,x) for x in parsed],[-1,-1,1])
    def test_json_duplicates_and_overflow_rejected(self):
        for text in ['{"x":1,"x":2}','{"x":NaN}','{"x":1e999}']:
            with self.assertRaises(ValueError):strict_json(text)
    def test_pair_local_identity_may_differ(self):
        readers=[]
        for rank in range(2):
            self.write(rank,fixture(rank));reader=RankRecords(self.ranks[rank]['local'],rank,EPOCH,INPUTS)
            reader.poll(final=True);readers.append(reader)
        self.assertEqual(validate_pair(readers)['complete_frames_per_rank'],[6,6])
    def test_pair_digest_mismatch(self):
        readers=[]
        for rank in range(2):
            rows=fixture(rank)
            if rank==1:rows[1]['frames'][0]['headerSHA256']='a'*64
            self.write(rank,rows);reader=RankRecords(self.ranks[rank]['local'],rank,EPOCH,INPUTS);reader.poll(final=True);readers.append(reader)
        with self.assertRaises(ValueError):validate_pair(readers)
    def run_fake(self,code,rows,memory=lambda:None):
        children=[];stops=[];clock=[0]
        def start(rank):
            i=rank['rank'];self.write(i,rows(i));p=Process(100+i,code(i));children.append(p);return p
        def stop(ranks,processes):
            stops.append(True)
            for process in processes:
                if process.code is None:process.code=-9
                process.wait()
        def sleep(seconds):clock[0]+=seconds
        result=supervise(self.ranks,EPOCH,2,start,stop,memory,lambda:clock[0],sleep)
        return result,children,stops
    def test_success_is_execution_not_baseline(self):
        result,children,stops=self.run_fake(lambda _:0,fixture)
        self.assertTrue(result['passed']);self.assertFalse(stops);self.assertTrue(all(p.waited for p in children))
        self.assertIsNone(result['validation']['baseline_comparison_passed'])
    def test_deadline_reaps_pair(self):
        result,children,stops=self.run_fake(lambda _:None,lambda i:[fixture(i)[0]])
        self.assertEqual(result['cancellation_reason'],'cohort_deadline');self.assertTrue(stops);self.assertTrue(all(p.waited for p in children))
    def test_peer_failure_reaps_other(self):
        result,children,stops=self.run_fake(lambda i:1 if i==0 else None,lambda _:[])
        self.assertEqual(result['cancellation_reason'],'rank_failed');self.assertTrue(stops)
    def test_memory_gate_reaps_pair(self):
        def fail():raise ValueError('new swap')
        result,children,stops=self.run_fake(lambda _:None,lambda _:[],fail)
        self.assertFalse(result['passed']);self.assertTrue(stops);self.assertTrue(all(p.waited for p in children))


if __name__=='__main__':unittest.main()
