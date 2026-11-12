"""Selected-plan and owner-path regressions using only fabricated records/fakes."""
import copy
import importlib.util
import json
from pathlib import Path
import socket
import subprocess
import tempfile
import unittest
from unittest.mock import patch

from long_pair_cut import selection_receipt, PLAN_SHA256
from long_rank_cut import validate_source
from long_rank_configuration import configuration, require_configuration
from long_rank_contract import validate
from long_rank_identity import canonical, sha
from long_rank_paths import paths
from long_rank_staging import prepare_ranks, verify_local_rank_inputs
from long_rank_supervision import supervise
from long_rank_test_support import EPOCH, INPUTS, RAW_PROMPT, ENDPOINTS, Child, fixtures


class CutTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(prefix='long-cut-rank-cpu-');self.addCleanup(self.temp.cleanup)
        self.root=Path(self.temp.name)
        for obj,name in [(subprocess,'Popen'),(subprocess,'run'),(socket,'socket')]:
            guard=patch.object(obj,name,side_effect=AssertionError('No real processes or sockets'))
            guard.start();self.addCleanup(guard.stop)

    def test_only_one_cut_pair_added_to_exact_owner_configuration(self):
        path=Path(__file__).parent/'originals/long_rank_configuration.py'
        spec=importlib.util.spec_from_file_location('cut_rank_original_configuration',path)
        old=importlib.util.module_from_spec(spec);spec.loader.exec_module(old)
        for policy in ('serial_v1','prompt_lookahead_one_v1'):
            for rank in (0,1):
                args=('/bundle','c'*64,'/model',INPUTS['prompt_file_sha256'],rank,EPOCH,policy)
                value=configuration(*args);index=value['arguments'].index('--stage-cut')
                self.assertEqual(value['arguments'].count('--stage-cut'),1)
                self.assertEqual(value['arguments'][index:index+2],['--stage-cut','12'])
                del value['arguments'][index:index+2]
                self.assertEqual(value,old.configuration(*args))

    def test_cut_and_both_owner_flags_are_required_exactly_once(self):
        args=('/bundle','c'*64,'/model',INPUTS['prompt_file_sha256'],0,EPOCH,'serial_v1')
        value=configuration(*args)
        for option in ('--stage-cut','--prefill-phase-trace-file','--prefill-owner-trace-file'):
            index=value['arguments'].index(option)
            for replacement in ([],value['arguments'][index:index+2]*2,[option,'wrong']):
                changed=copy.deepcopy(value);changed['arguments'][index:index+2]=replacement
                with self.assertRaises(ValueError):require_configuration(changed,*args)

    def test_ready_rejects_coherently_rehashed_wrong_selected_plan(self):
        for key in ('planFingerprint','producerStageFingerprint','consumerStageFingerprint',
                    'producerConstructionConfigurationSHA256','consumerConstructionConfigurationSHA256'):
            rows=fixtures(0);rows[0]['agreement'][key]='e'*64
            for row in rows:row['agreementFingerprint']=sha(b'qwen-profiled-prefill-start-agreement-v1\n'+canonical(row['agreement']))
            with self.assertRaises(ValueError):validate(rows[0],0,0,EPOCH,'serial_v1',INPUTS)

    def test_final_rejects_local_plan_configuration_or_role_drift(self):
        for rank in (0,1):
            for key,value in [('planSHA256','e'*64),('stagePlanSHA256','e'*64),
                              ('constructionConfigurationSHA256','e'*64),('sourceParameterLayoutSHA256','e'*64),
                              ('stageIndex',1-rank),('sourceModelTensorBytes',5038041600.0)]:
                rows=fixtures(rank);rows[1]['sourceLoad'][key]=value
                validate(rows[0],0,rank,EPOCH,'serial_v1',INPUTS)
                with self.assertRaises(ValueError):validate(rows[1],1,rank,EPOCH,'serial_v1',INPUTS,rows[0])

    def test_final_observed_storage_must_match_validated_agreement(self):
        rows=fixtures(1);rows[1]['sourceLoad']['storageCommitmentSHA256']='e'*64
        with self.assertRaises(ValueError):validate(rows[1],1,1,EPOCH,'serial_v1',INPUTS,rows[0])

    def test_direct_source_role_rejects_boolean_and_out_of_range(self):
        rows=fixtures(0)
        for rank in (False,True,-1,2):
            with self.assertRaises(ValueError):validate_source(rows[1]['sourceLoad'],rank,rows[0]['agreement'])

    def test_selected_receipt_and_sixteen_frames_remain_unqualified(self):
        receipt=selection_receipt()
        self.assertEqual(receipt['source_layer_ranges'],[[0,12],[12,32]])
        self.assertEqual(receipt['plan_sha256'],PLAN_SHA256)
        self.assertFalse(receipt['independent_numerical_comparison_run'])
        for rank in (0,1):
            rows=fixtures(rank)
            self.assertEqual(len(rows[1]['request']['steps']),16)
            self.assertEqual(rows[1]['request']['request']['chunkSize'],512)
            self.assertEqual(rows[0]['agreement']['frameCount'],16)
            self.assertFalse(rows[1]['throughputMeasurementValid'])

    def test_actual_rank_paths_drive_four_separate_sidecar_leaves(self):
        layout=paths('/home/owner','/runs','/models/pinned',EPOCH)
        self.assertEqual(layout['bundle'],layout['run']+'/bundle')
        self.assertEqual(layout['rank_directories'],[layout['run']+'/rank-0',layout['run']+'/rank-1'])
        (self.root/'inputs').mkdir();(self.root/'inputs/prompt.json').write_bytes(RAW_PROMPT)
        inputs=dict(INPUTS,files=[])
        ranks,control=prepare_ranks(self.root,layout,'fixture-peer','b'*64,'c'*64,inputs,ENDPOINTS,EPOCH,'serial_v1')
        verify_local_rank_inputs(self.root,control,inputs,'serial_v1')
        leaves=[]
        for rank in ranks:
            config=json.loads((Path(rank['local'])/'rank.json').read_bytes())
            self.assertEqual(config['bundle'],layout['run']+'/bundle')
            self.assertEqual(config['input_files'],{})
            self.assertEqual((Path(rank['local'])/'prompt.json').read_bytes(),RAW_PROMPT)
            for option,leaf in [('--prefill-phase-trace-file','phase-trace.json'),('--prefill-owner-trace-file','owner-trace.json')]:
                self.assertEqual(config['arguments'][config['arguments'].index(option)+1],'@rank/'+leaf)
                leaves.append(rank['directory']+'/'+leaf)
        self.assertEqual(len(set(leaves)),4)
        self.assertTrue(all('/native/' not in path for path in leaves))

    def test_exact_rank_config_check_rejects_coherent_old_solo_bundle_layout(self):
        layout=paths('/home/owner','/runs','/models/pinned',EPOCH)
        args=(layout['bundle'],'c'*64,layout['model'],INPUTS['prompt_file_sha256'],0,EPOCH,'serial_v1')
        changed=configuration(*args);changed['bundle']=layout['run']+'/native/bundle'
        with self.assertRaises(ValueError):require_configuration(changed,*args)

    def test_deadline_expiring_inside_observation_fences_completed_cohort(self):
        class Reader:
            def __init__(self,_directory,rank,*_):self.rows=fixtures(rank)
            def poll(self,final=False):pass
        now=[0.0];children=[Child(7000,0),Child(7001,0)];stops=[]
        ranks=[dict(rank=i,local='/unused/'+str(i)) for i in (0,1)]
        def memory(_):now[0]=331.0
        with patch('long_rank_supervision.Records',Reader):
            result=supervise(ranks,INPUTS,EPOCH,'serial_v1',330,lambda rank:children[rank['rank']],
                lambda owners,started:stops.append((owners,started)),memory,clock=lambda:now[0],sleep=lambda _:None)
        self.assertFalse(result['passed']);self.assertEqual(result['cancellation_reason'],'local_parent_deadline')
        self.assertEqual(len(stops),1);self.assertEqual(len(stops[0][0]),2)
        self.assertEqual([p.waits for p in children],[1,1])
        self.assertFalse(result['remote_process_reaping_independently_verified'])


if __name__=='__main__':unittest.main()
