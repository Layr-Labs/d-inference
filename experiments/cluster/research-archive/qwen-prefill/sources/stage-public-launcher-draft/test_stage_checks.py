"""Pure draft tests; no native binary, socket, system command or model payload."""
import copy
import math
from pathlib import Path
import struct
import tempfile
import unittest
from unittest.mock import patch
from stage_checks import configuration,evidence,request
from stage_checks.common import digest,parse
from stage_checks.resources import MemoryGate
from stage_checks.stream import Records
from stage_checks.supervision import run

EPOCH='a'*32


class Tests(unittest.TestCase):
    def setUp(self):
        for target in ('subprocess.Popen','subprocess.run','socket.socket'):
            guard=patch(target,side_effect=AssertionError('No native/process/socket calls'))
            guard.start();self.addCleanup(guard.stop)
    def test_workload_bounds_and_dynamic_schedule(self):
        for count,chunk,outputs in [(1,1,1),(5,2,2),(128,32,4),(128,1,4)]:
            record,_=request.make_request(EPOCH,[7]*count,[8]*(outputs-1),chunk,64)
            self.assertEqual(len(record['steps']),(count+chunk-1)//chunk+outputs-1)
            self.assertEqual(record['steps'][-1]['frame']['tokenOffset']+record['steps'][-1]['frame']['tokenCount'],count+outputs-1)
            request.validate(record,record)
    def test_request_rejects_booleans_out_of_vocab_and_counts(self):
        for prompt,teacher,chunk in [([True],[],1),([64],[],1),([],[],1),([1]*129,[],1),([1],[1]*4,1),([1],[],33)]:
            with self.assertRaises(ValueError):request.make_request(EPOCH,prompt,teacher,chunk,64)
    def test_request_uuid_and_hash_are_bound(self):
        expected,_=request.make_request(EPOCH,[1,2],[3],2,64)
        for key,value in [('fingerprint','b'*64),('teacherTokenIDs',[4])]:
            actual=copy.deepcopy(expected);actual[key]=value
            with self.assertRaises(ValueError):request.validate(actual,expected)
    def test_one_output_omits_teacher_flag(self):
        recorded,_=request.make_request(EPOCH,[1],[],1,64)
        context=dict(mode='ranks',model='/not-opened',artifact='b'*64,request=recorded)
        config=configuration.build(0,EPOCH,context,'/bundle','c'*64,[['127.0.0.1:20001'],['127.0.0.1:20002']],180)
        self.assertNotIn('--teacher-tokens-file',config['arguments'])
        self.assertEqual(config['arguments'][config['arguments'].index('--decode-tokens')+1],'1')
        self.assertNotIn('--synthetic',config['arguments'])
    def test_p2p_has_no_model_or_tp_flags(self):
        config=configuration.build(1,EPOCH,dict(mode='p2p'),'/bundle','c'*64,[['127.0.0.1:20001'],['127.0.0.1:20002']],60)
        self.assertIn('--synthetic',config['arguments']);self.assertNotIn('--model-dir',config['arguments'])
        self.assertNotIn('--partition',config['arguments']);self.assertNotIn('model_directory',config)
    def test_no_remote_or_duplicate_endpoint(self):
        for hosts in [[['example:3'],['127.0.0.1:4']],[['127.0.0.1:3'],['127.0.0.1:3']]]:
            with self.assertRaises(ValueError):configuration.build(0,EPOCH,dict(mode='p2p'),'/b','c'*64,hosts,60)
    def test_signed_zero_and_exact_native_logit_bytes(self):
        values=parse('[0,-0,1,-1]')
        for dtype,raw in [('float32',b''.join(struct.pack('<f',x)for x in values)),('float16',b''.join(struct.pack('<e',x)for x in values)),('bfloat16',b''.join(struct.pack('<H',struct.unpack('<I',struct.pack('<f',x))[0]>>16)for x in values))]:
            row=dict(shape=[1,4],dtype=dtype,byteCount=len(raw),logicalBytesSHA256=digest(raw),values=values)
            self.assertEqual(evidence.logit_bytes(row,4),raw)
        self.assertLess(math.copysign(1,values[1]),0)
    def test_logit_hash_nonfinite_and_truncation_rejected(self):
        row=dict(shape=[1,4],dtype='float32',byteCount=16,logicalBytesSHA256='a'*64,values=[0,0,0,0])
        with self.assertRaises(ValueError):evidence.logit_bytes(row,4)
        row['values']=[True,0,0,0]
        with self.assertRaises(ValueError):evidence.logit_bytes(row,4)
        for data in ['{"x":1,"x":2}','[NaN]','[1e999]']:
            with self.assertRaises(ValueError):parse(data)
    def test_native_bf16_requires_exact_values(self):
        row=dict(shape=[1,1],dtype='bfloat16',byteCount=2,logicalBytesSHA256='a'*64,values=[1.001])
        with self.assertRaises(ValueError):evidence.logit_bytes(row,1)
    def test_kernel_one_empty_conv_namespace(self):
        text=dict(num_hidden_layers=4,full_attention_interval=2,num_key_value_heads=1,head_dim=32,
                  linear_num_key_heads=1,linear_key_head_dim=32,linear_num_value_heads=1,linear_value_head_dim=32,linear_conv_kernel_dim=1)
        entries=[]
        for layer,component,shape,dtype in [(0,'conv',[1,0,96],'bfloat16'),(0,'ssm',[1,1,32,32],'float32'),
            (1,'kv.keys',[1,1,1,32],'float16'),(1,'kv.position_offsets',[1],'int32'),(1,'kv.values',[1,1,1,32],'float16')]:
            size=math.prod(shape)*({'bfloat16':2,'float16':2,'float32':4,'int32':4}[dtype])
            entries.append(dict(globalLayerIndex=layer,component=component,shape=shape,dtype=dtype,byteCount=size,sha256=digest(bytes(size))))
        total,fingerprint=evidence.state_entries(entries,text,0,1)
        self.assertGreater(total,0);self.assertEqual(len(fingerprint),64)
        entries[0]['sha256']='a'*64
        with self.assertRaises(ValueError):evidence.state_entries(entries,text,0,1)
    def test_state_global_owner_rejected(self):
        text=dict(num_hidden_layers=4,full_attention_interval=2,num_key_value_heads=1,head_dim=32,
                  linear_num_key_heads=1,linear_key_head_dim=32,linear_num_value_heads=1,linear_value_head_dim=32,linear_conv_kernel_dim=1)
        with self.assertRaises(ValueError):evidence.state_entries([],text,0,1)
    def test_zero_new_swap_and_pressure_gates(self):
        for next_value in [dict(pressure_level=4,swap_used_bytes='0'),dict(pressure_level=1,swap_used_bytes='1')]:
            samples=iter([dict(pressure_level=1,swap_used_bytes='0'),next_value]);gate=MemoryGate(lambda:next(samples))
            with self.assertRaises(ValueError):gate.observe()


if __name__=='__main__':unittest.main()
