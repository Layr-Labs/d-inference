"""Small CPU schema/chronology controls; no native/model or sidecar evidence."""
import copy
import importlib.util
from pathlib import Path
import sys
import unittest

ROOT=Path(__file__).resolve().parents[1]
BASE=ROOT.parent.parent/'gemma4-mtp-remote-packed-head-physical-20260920'
sys.path[:0]=[str(ROOT/'proposed/remote/package'),str(BASE/'package')]
from workload_contract import counts,state_geometry,target_extra_logical_bytes
from remote_mtp_contract import validate_inputs,validate_metadata_depth,validate_verification_widths

def job(p=128,o=128):
    return dict(schema='gemma4_resident_benchmark_v1',mode='full',promptCount=p,outputCount=o,
        chunkSize=64,cut=7,residualDType='bfloat16',prefillPolicy='serial',timeoutSeconds=300)

class OutputEnvelope(unittest.TestCase):
    def test_old_o16_counts_unchanged(self):
        for p in (128,4096):
            c=counts(job(p,16));self.assertEqual((c['decode'],c['frontier'],c['maximumTokens'],c['measuredDecodeTokens'],c['allGeneratedTokens']),
                (15,p+15,p+16,45,64))
    def test_long_counts_and_forward_frontier(self):
        for p in (128,4096):
            c=counts(job(p));self.assertEqual((c['decode'],c['frontier'],c['maximumTokens'],c['measuredDecodeTokens'],c['allGeneratedTokens'],c['frames']),
                (127,p+127,p+128,381,512,p//64+127))
    def test_no_implicit_or_intermediate_output(self):
        for value in (True,False,16.0,128.0,0,1,15,17,127,129,'128',None):
            with self.assertRaises(ValueError):counts(job(o=value))
        value=job();del value['outputCount']
        with self.assertRaises(ValueError):counts(value)
    def test_workload_stays_closed(self):
        for field,value in [('promptCount',8192),('promptCount',128.0),('chunkSize',128),('cut',8),('mode','stage0'),
            ('residualDType','float32'),('prefillPolicy','lookahead'),('timeoutSeconds',315),('timeoutSeconds',300.0)]:
            v=job();v[field]=value
            with self.assertRaises(ValueError):counts(v)
    def test_short_window_and_full_ranges(self):
        for frontier in (143,255):
            self.assertEqual(state_geometry(dict(dtype='bfloat16',window=1024,kvHeads=8,headDimension=256),'kv.keys',frontier),
                ('bfloat16',[1,8,frontier,256],4096*frontier,[0,frontier]))
    def test_long_sliding_state_uses_latest_1024(self):
        for frontier in (4111,4223):
            self.assertEqual(state_geometry(dict(dtype='bfloat16',window=1024,kvHeads=8,headDimension=256),'kv.values',frontier),
                ('bfloat16',[1,8,1024,256],4194304,[frontier-1024,frontier]))
    def test_long_full_state_keeps_entire_frontier(self):
        self.assertEqual(state_geometry(dict(dtype='bfloat16',window=0,kvHeads=2,headDimension=512),'kv.keys',4223),
            ('bfloat16',[1,2,4223,512],8648704,[0,4223]))
    def test_position_is_scalar_and_not_windowed(self):
        self.assertEqual(state_geometry({},'kv.position_offsets',4223),('int32',[1],4,[]))
    def test_state_domain_and_frontier_refuse(self):
        layer=dict(dtype='bfloat16',window=1024,kvHeads=8,headDimension=256)
        for frontier in (True,0,4224,4223.0):
            with self.assertRaises(ValueError):state_geometry(layer,'kv.keys',frontier)
        with self.assertRaises(ValueError):state_geometry(layer,'kv.unknown',255)
    def test_exact_existing_logical_reserves(self):
        self.assertEqual(target_extra_logical_bytes(job(128,16)),43568162)
        self.assertEqual(target_extra_logical_bytes(job(4096,16)),90508322)
    def test_only_frontier_derived_reserve_growth(self):
        self.assertEqual(target_extra_logical_bytes(job(128,128)),46320674)
        self.assertEqual(target_extra_logical_bytes(job(4096,128)),91425826)
        self.assertEqual(target_extra_logical_bytes(job(4096,128))-target_extra_logical_bytes(job(4096,16)),112*8192)
    def test_depth_one_cannot_verify_three_columns(self):
        validate_metadata_depth(dict(maximumDraftTokens=1,maximumBufferedProposals=5),dict(maximumDraftTokens=1))
        validate_verification_widths([1,2,1],dict(maximumDraftTokens=1))
        with self.assertRaises(ValueError):validate_verification_widths([1,3],dict(maximumDraftTokens=1))
    def test_helper_copies_are_identical(self):
        expected=(ROOT/'proposed/local/workload_contract.py').read_bytes()
        for name in ('local/package','remote/package','numerical'):
            self.assertEqual((ROOT/'proposed'/name/'workload_contract.py').read_bytes(),expected)
    def test_empty_member_fix_is_retained(self):
        self.assertIn("empty=(row['bytes']==0)",(ROOT/'proposed/numerical/compare.py').read_text())
    def test_resource_bijection_order_independent_and_strict(self):
        spec=importlib.util.spec_from_file_location('o128_prepare',ROOT/'prepare.py')
        m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
        names=('mlx.metallib','mlx-swift-lm_MLXLMCommon.bundle/pagedattention.metal')
        expected=[dict(path='bundle/'+name,bytes=i+1,sha256=str(i)*64) for i,name in enumerate(names)]
        actual=[dict(row,path='/private/native/'+row['path'].removeprefix('bundle/')) for row in expected]
        m.bind_resources(list(reversed(actual)),expected)
        bad=copy.deepcopy(actual);bad[0]['sha256']='f'*64
        with self.assertRaises(AssertionError):m.bind_resources(bad,expected)
        with self.assertRaises(AssertionError):m.bind_resources([actual[0],actual[0]],expected)

if __name__=='__main__':unittest.main()
