"""Short rank admission and teacher staging with fabricated CPU-only files."""
import ast
import copy
import hashlib
import importlib.util
import json
import math
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import types
import unittest
from unittest.mock import patch
from long_rank_configuration import configuration,require_configuration,timeout,hostfile
from long_rank_contract import validate
from long_rank_identity import canonical,sha
from long_rank_paths import paths,host_alias,BOOTSTRAP,PINNED_RUNNER
from long_rank_records import Records,parse,MAX_STDOUT,MAX_LINE
from long_rank_staging import prepare_ranks,verify_local_rank_inputs,verify_remote
from long_rank_warning import source_warning,check_stderr,WARNING
from long_rank_client import RemoteMemoryGate
from long_rank_artifacts import rank_file_receipts
from long_rank_test_support import EPOCH,ENDPOINTS,INPUTS,RAW_PROMPT,RAW_TEACHER,fixtures,write_records


class Tests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup);self.root=Path(self.temp.name)
        for obj,name in [(subprocess,'Popen'),(subprocess,'run'),(socket,'socket')]:
            guard=patch.object(obj,name,side_effect=AssertionError('Real process/socket forbidden'));guard.start();self.addCleanup(guard.stop)

    def test_fixed_cut_request_and_rank_path_constructor_are_source_bound(self):
        source=Path(__file__).with_name('long_rank_paths.py')
        self.assertEqual(sha(source.read_bytes()),'ca1b6cd8dc9ecd34c3ca41f5ee6f9aeb26b7efd38b2e6630a4da69d994cc36fe')
        layout=paths('/home/fixture',None,'/models/qwen',EPOCH)
        self.assertEqual(layout['bundle'],layout['run']+'/bundle')
        self.assertEqual(layout['rank_directories'],[layout['run']+'/rank-'+str(i) for i in (0,1)])
        for rank in (0,1):
            value=configuration(layout['bundle'],'b'*64,'/model',INPUTS['prompt_file_sha256'],INPUTS['teacher_file_sha256'],rank,EPOCH)
            self.assertEqual(value['input_files'],{});self.assertEqual(value['environment_files'],{'MLX_HOSTFILE':'hosts.json'})
            self.assertEqual(value['environment'],dict(DARKBLOOM_BF16_WEIGHTS='1',DARKBLOOM_CBV2_ATTN_QUERY_BLOCK='128',MLX_ENABLE_TF32='1',MLX_RANK=str(rank)))
            self.assertEqual(value['timeout_seconds'],180)
            args=value['arguments']
            for key,wanted in [('--mode','qwen-layer-stage-rank-check'),('--stage-cut','12'),('--prompt-tokens','65'),
                ('--chunk-size','32'),('--decode-tokens','4'),('--seed','7'),('--teacher-tokens-file','@rank/teacher.json')]:
                self.assertEqual(args[args.index(key)+1],wanted)
            for flag in ('--stage-prefill-policy','--stage-logits-dtype','--long-prompt-sha256','--prefill-phase-trace-file'):self.assertNotIn(flag,args)
            wrong=copy.deepcopy(value);wrong['bundle']=layout['run']+'/native/bundle'
            with self.assertRaises(ValueError):require_configuration(wrong,layout['bundle'],'b'*64,'/model',INPUTS['prompt_file_sha256'],INPUTS['teacher_file_sha256'],rank,EPOCH)
        for policy in ('serial_v1','prompt_lookahead_one_v1','serial'):
            with self.assertRaises(ValueError):configuration('/b','b'*64,'/m','c'*64,'d'*64,0,EPOCH,policy)
        for seconds in (0,211,True,210.0):
            with self.assertRaises(ValueError):timeout(seconds)
        timeout(210)

    def staged(self):
        (self.root/'inputs').mkdir();(self.root/'inputs/prompt.json').write_bytes(RAW_PROMPT);(self.root/'inputs/teacher.json').write_bytes(RAW_TEACHER)
        inputs=dict(INPUTS,files=[]);layout=paths('/home/fixture',None,'/models/qwen',EPOCH)
        ranks,config=prepare_ranks(self.root,layout,'fixture-peer','b'*64,'c'*64,inputs,ENDPOINTS,EPOCH)
        return inputs,layout,ranks,config

    def test_both_raw_teacher_copies_and_mutation_rejection(self):
        inputs,layout,ranks,config=self.staged();verify_local_rank_inputs(self.root,config,inputs)
        for rank in (0,1):
            directory=self.root/('rank-'+str(rank));self.assertEqual((directory/'teacher.json').read_bytes(),RAW_TEACHER)
            self.assertEqual(config['ranks'][rank]['teacher_sha256'],INPUTS['teacher_file_sha256'])
            self.assertEqual(json.loads((directory/'rank.json').read_text())['bundle'],layout['bundle'])
        (self.root/'rank-1/teacher.json').chmod(0o600);(self.root/'rank-1/teacher.json').write_bytes(b'[1,2,3]')
        with self.assertRaises(ValueError):verify_local_rank_inputs(self.root,config,inputs)

    def test_closed_short_outer_scope_and_stale_identity_rejected(self):
        for rank in (0,1):
            rows=fixtures(rank);validate(rows[0],0,rank,EPOCH,None,INPUTS);validate(rows[1],1,rank,EPOCH,None,INPUTS,rows[0])
        mutations=[lambda r:r[0].update(kind='qwen_long_prefill_rank_ready'),lambda r:r[0].update(schemaVersion=True),
            lambda r:r[0].update(extra=True),lambda r:r[1].update(modelReleased=False),lambda r:r[1].update(throughputMeasurementValid=True),
            lambda r:r[1]['sourceLoad'].update(planSHA256='f'*64),lambda r:r[1]['sourceLoad'].update(stageIndex=1),
            lambda r:r[1]['request']['teacherTokenIDs'].__setitem__(0,9),lambda r:r[1]['request']['request'].update(requestID='f'*36),
            lambda r:r[1]['frames'].pop(),lambda r:r[1]['frames'][0]['capture'].update(sourceLayerEnd=16),
            lambda r:r[1]['frames'][0]['capture']['identity'].update(planFingerprint='f'*64),
            lambda r:r[1]['frames'][0].update(completedTransportPhase='received_only'),
            lambda r:r[1]['memory'][-1].update(cachedMLXBytes=1)]
        for mutation in mutations:
            rows=copy.deepcopy(fixtures(0));mutation(rows)
            with self.assertRaises(ValueError):
                validate(rows[0],0,0,EPOCH,None,INPUTS);validate(rows[1],1,0,EPOCH,None,INPUTS,rows[0])

    def test_output_bounds_signed_zero_and_opaque_numerical_content(self):
        self.assertEqual((MAX_STDOUT,MAX_LINE),(64*1024**2,60*1024**2))
        self.assertLess(math.copysign(1,parse('[-0]')[0]),0)
        write_records(self.root,fixtures(0));reader=Records(self.root,0,EPOCH,None,INPUTS);reader.poll(True)
        self.assertEqual(len(reader.rows),2)
        path=self.root/'stdout.jsonl'
        with path.open('wb') as stream:stream.truncate(MAX_STDOUT+1)
        with self.assertRaises(ValueError):Records(self.root,0,EPOCH,None,INPUTS).poll()
        rank=self.root/'rank-0';rank.mkdir();(rank/'stdout.jsonl').touch()
        with (rank/'stdout.jsonl').open('wb') as stream:stream.truncate(MAX_STDOUT+1)
        result=rank_file_receipts(self.root);self.assertIsNone(result[0]['sha256']);self.assertTrue(result[0]['hash_omitted_because_oversized'])

    def test_warning_exact_prefix_then_one_terminal_line(self):
        path=self.root/'stderr.log'
        for count in (0,3,len(WARNING)):
            path.write_bytes(WARNING[:count]);check_stderr(path)
        check_stderr(path,True)
        for raw in (b'',WARNING[:-1],WARNING+b'x',WARNING+WARNING,b'other\n'):
            path.write_bytes(raw)
            with self.assertRaises(ValueError): check_stderr(path,True)

    def test_source_bound_warning_logger(self):
        base=self.root/'source/experiments/cluster/inference/Sources/ClusterInference';base.mkdir(parents=True)
        literal='log("'+WARNING.decode().rstrip('\n')+'")'
        (base/'Collective.swift').write_text('if transport == .loopbackTest {\n            '+literal+'\n}')
        (base/'Options.swift').write_text('func log(_ message: String) {\n    FileHandle.standardError.write(Data((message + "\\n").utf8))\n}')
        self.assertEqual(source_warning(self.root)['expected_utf8'],WARNING.decode())
        (base/'Options.swift').write_text('different logger')
        with self.assertRaises(ValueError): source_warning(self.root)

    def test_partial_records_duplicate_keys_and_missing_warning(self):
        rows=fixtures(0);data=canonical(rows[0])+b'\n'+canonical(rows[1])+b'\n'
        path=self.root/'stdout.jsonl';(self.root/'stderr.log').write_bytes(WARNING)
        reader=Records(self.root,0,EPOCH,None,INPUTS)
        path.write_bytes(data[:31]);reader.poll();path.write_bytes(data);reader.poll(True)
        self.assertEqual(len(reader.rows),2)
        with self.assertRaises(ValueError): parse(b'{"rank":0,"\\u0072ank":1}')
        with self.assertRaises(ValueError): parse(b'{"x":NaN}')
        (self.root/'stderr.log').write_bytes(b'')
        with self.assertRaises(ValueError): reader.poll(True)

    def test_remote_paths_and_bootstrap_are_narrow(self):
        for bad in ('-option','a b','user@host','a;echo'):
            with self.assertRaises(ValueError):host_alias(bad)
        with self.assertRaises(ValueError): paths('/home/f',None,'/home/f/DarkbloomDev/cluster-runs/model',EPOCH)
        for bad in ([[['x']]], [['127.0.0.1:1'],['127.0.0.1:1']], [['127.0.0.1:01'],['127.0.0.1:2']]):
            with self.assertRaises(ValueError):hostfile(bad)
        self.assertIn("s.bind(('127.0.0.1',0))",BOOTSTRAP)
        self.assertIn('raceFailsWithoutFallback=True',BOOTSTRAP)
        self.assertIn('long_rank_control.py',PINNED_RUNNER)

    def test_resource_gate_requires_zero_swap_and_preserves_missing_rss(self):
        def sample(pressure=1,swap='0'):return dict(pressure_level=pressure,swap_used_bytes=swap,remote_pid_inventory={'observed_processes':[]})
        gate=RemoteMemoryGate();gate.consume(sample());self.assertEqual(gate.samples[0]['remote_pid_inventory']['observed_processes'],[])
        for value in (sample(4),sample(swap='1'),sample(swap='NaN'),sample(swap='-1')):
            with self.assertRaises(ValueError):RemoteMemoryGate().consume(value)

    def test_remote_control_input_seals_and_rank_pid_attribution(self):
        stub=types.ModuleType('artifacts')
        for name in ('file_sha256','verify_files','verify_model'):setattr(stub,name,lambda *args:None)
        path=Path(__file__).parent/'long_rank_control.py'
        with patch.dict(sys.modules,{'artifacts':stub}):
            spec=importlib.util.spec_from_file_location('cpu_long_control',path);m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
        config=dict(bundle='/owned/bundle',ranks=[dict(rank=i,directory='/owned/rank-'+str(i)) for i in range(2)])
        raw='10 1 10 99 /owned/bundle/cluster-inference --tokens-file /owned/rank-1/prompt.json\n11 1 11 2 /usr/bin/python3 /owned/bundle/rank_worker.py /owned/rank-0/rank.json\n'
        result=m.parse_process_inventory(raw,config)['observed_processes']
        self.assertEqual([(r['kind'],r['rank'],r['rssBytes']) for r in result],[('native',1,99*1024),('supervisor',0,2048)])
        with self.assertRaises(ValueError):m.parse_process_inventory(raw.replace('/owned/rank-1/prompt.json','/elsewhere/prompt.json'),config)
        source=path.read_text();self.assertLess(source.index("for name, key, size_key, maximum"),source.index("rank_records.append(item)"))
        self.assertIn("if phase == 'before': path.chmod(0o400)",source)

    def test_all_sources_parse_as_python39(self):
        for path in Path(__file__).parent.glob('*.py'):ast.parse(path.read_text(),filename=str(path),feature_version=(3,9))


if __name__=='__main__':unittest.main()
