"""Pure v4 launch/admission tests. Every real process/socket entry is blocked."""
import ast
import copy
import importlib.util
import json
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import types
import unittest
from unittest.mock import patch
from long_reference_inputs import archive_inputs, parse_prompt, ARTIFACT, require
from long_rank_configuration import configuration, timeout, hostfile
from long_rank_contract import validate
from long_rank_identity import canonical, sha, recorded_request
from long_rank_paths import host_alias, paths, BOOTSTRAP, PINNED_RUNNER
from long_rank_records import Records, parse, MAX_STDOUT
from long_rank_staging import prepare_ranks, verify_local_rank_inputs, verify_remote
from long_rank_warning import source_warning, check_stderr, WARNING
from long_rank_client import RemoteMemoryGate
from long_rank_test_support import EPOCH, ENDPOINTS, INPUTS, RAW_PROMPT, fixtures, write_records


class Tests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='long-rank-cpu-'); self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        for obj,name in [(subprocess,'Popen'),(subprocess,'run'),(socket,'socket')]:
            p = patch.object(obj,name,side_effect=AssertionError('Real process/socket forbidden')); p.start(); self.addCleanup(p.stop)

    def test_exact_configuration_both_policies_and_raw_maps(self):
        for policy in ('serial_v1','prompt_lookahead_one_v1'):
            for rank in (0,1):
                value = configuration('/bundle','b'*64,'/model',INPUTS['prompt_file_sha256'],rank,EPOCH,policy)
                self.assertEqual(value['input_files'],{}); self.assertEqual(value['environment_files'],{'MLX_HOSTFILE':'hosts.json'})
                self.assertEqual(value['environment']['MLX_RANK'],str(rank)); self.assertEqual(value['timeout_seconds'],300)
                self.assertIn('qwen-long-prefill-rank-check',value['arguments'])
                self.assertEqual(value['arguments'][value['arguments'].index('--seed')+1],'7')
        for bad in ('serial','lookahead-one','unknown'):
            with self.assertRaises(ValueError): configuration('/b','b'*64,'/m','c'*64,0,EPOCH,bad)
        for value in (0,331,True):
            with self.assertRaises(ValueError): timeout(value)

    def test_raw_prompt_archive_preserves_whitespace_and_pin(self):
        prompt,origin=self.root/'prompt.json',self.root/'origin.json'
        prompt.write_bytes(RAW_PROMPT); origin.write_bytes(b'{"fake": true}\n')
        result=archive_inputs(prompt,sha(RAW_PROMPT),origin,sha(origin.read_bytes()),self.root)
        self.assertEqual((self.root/'inputs/prompt.json').read_bytes(),RAW_PROMPT)
        self.assertFalse(result['raw_prompt_reencoded'])
        with self.assertRaises(ValueError): parse_prompt(b'[3.0]')
        with self.assertRaises(ValueError): parse_prompt(RAW_PROMPT.replace(b'3',b'-0',1))

    def test_staging_binds_both_rank_raw_files_before_and_after(self):
        (self.root/'inputs').mkdir(); (self.root/'inputs/prompt.json').write_bytes(RAW_PROMPT)
        inputs=dict(INPUTS,files=[])
        layout=paths('/home/fixture',None,'/models/qwen',EPOCH)
        ranks,config=prepare_ranks(self.root,layout,'fixture-peer','b'*64,'c'*64,inputs,ENDPOINTS,EPOCH,'serial_v1')
        verify_local_rank_inputs(self.root,config,inputs,'serial_v1')
        self.assertEqual(len(ranks),2)
        for i in range(2): self.assertEqual((self.root/('rank-'+str(i))/'prompt.json').read_bytes(),RAW_PROMPT)
        (self.root/'rank-0/prompt.json').chmod(0o600)
        (self.root/'rank-0/prompt.json').write_bytes(RAW_PROMPT+b' ')
        with self.assertRaises(ValueError): verify_local_rank_inputs(self.root,config,inputs,'serial_v1')

    def test_outer_records_and_both_policies(self):
        for policy in ('serial_v1','prompt_lookahead_one_v1'):
            for rank in (0,1):
                rows=fixtures(rank,policy)
                validate(rows[0],0,rank,EPOCH,policy,INPUTS)
                validate(rows[1],1,rank,EPOCH,policy,INPUTS,rows[0])

    def test_closed_identity_policy_request_environment_rejections(self):
        changes=[lambda r:r[0].update(envelopeVersion=3),lambda r:r[0].update(schemaVersion=True),
            lambda r:r[0].update(epoch='f'*32),lambda r:r[0].update(extra=True),
            lambda r:r[1].update(modelReleased=False),lambda r:r[1].update(throughputMeasurementValid=True),
            lambda r:r[1]['request']['steps'][2]['tokenIDs'].__setitem__(0,4),
            lambda r:r[1]['arithmeticEnvironment']['requiredValues'].update(MLX_ENABLE_TF32='0'),
            lambda r:r[1]['sourceLoad'].update(stageIndex=1)]
        for mutate in changes:
            rows=copy.deepcopy(fixtures(0));mutate(rows)
            with self.assertRaises(ValueError):
                validate(rows[0],0,0,EPOCH,'serial_v1',INPUTS)
                validate(rows[1],1,0,EPOCH,'serial_v1',INPUTS,rows[0])

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
        reader=Records(self.root,0,EPOCH,'serial_v1',INPUTS)
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
