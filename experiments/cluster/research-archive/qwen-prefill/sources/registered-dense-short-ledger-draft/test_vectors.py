"""CPU metadata substitution tests, not execution of production Swift."""
import copy
import json
from pathlib import Path
import unittest
from derive_vectors import derive

FIXTURE=Path('/Users/developer/DarkbloomDev/d-inference/experiments/cluster/inference/Tests/RegisteredDenseProfiles/retained-inputs.json')

class Vectors(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.inputs=json.loads(FIXTURE.read_text())

    def test_pinned_exact_vectors(self):
        expected=json.loads((Path(__file__).parent/'vectors.json').read_text())['vectors']
        self.assertEqual({k:derive(v) for k,v in self.inputs.items()},expected)

    def test_each_frontier_adds_two_kv_rows_and_capacity_is_fifth(self):
        for name,entry in self.inputs.items():
            v=derive(entry); step=v['attention_layers']*2*4*256*2
            values=v['frontier_logical_bytes']+[v['native_capacity5_state_bytes']]
            self.assertEqual([b-a for a,b in zip(values,values[1:])],[step]*3)

    def test_pair_delta_preserves_baseline_cpu_history(self):
        for entry in self.inputs.values():
            v=derive(entry)
            self.assertEqual(v['identity_allocator_pair_reserve_bytes']-v['identity_allocator_full_reserve_bytes'],
                             v['pair_minus_full_reserve_bytes'])
            self.assertGreater(v['pair_cpu_evidence_bytes'],v['full_cpu_evidence_bytes'])
            self.assertEqual(v['component_count'],v['layers']*9//4)

    def test_changed_fusion_shape_is_refused(self):
        v=copy.deepcopy(self.inputs['nine'])
        next(x for x in v['canonicalTensors'] if x['name'].endswith('layers.0.linear_attn.in_proj_a.weight'))['shape'][1]+=1
        with self.assertRaises(AssertionError):derive(v)

    def test_changed_fusion_dtype_is_refused(self):
        v=copy.deepcopy(self.inputs['twentySeven'])
        next(x for x in v['canonicalTensors'] if x['name'].endswith('layers.0.linear_attn.in_proj_a.scales'))['sourceDType']='F32'
        with self.assertRaises(AssertionError):derive(v)

    def test_changed_fusion_bytecount_is_refused(self):
        v=copy.deepcopy(self.inputs['nine'])
        next(x for x in v['canonicalTensors'] if x['name'].endswith('layers.0.linear_attn.in_proj_a.biases'))['byteCount']+=1
        with self.assertRaises(AssertionError):derive(v)

    def test_missing_fusion_component_is_refused(self):
        v=copy.deepcopy(self.inputs['twentySeven'])
        v['canonicalTensors']=[x for x in v['canonicalTensors'] if not x['name'].endswith('layers.0.linear_attn.in_proj_a.biases')]
        with self.assertRaises(KeyError):derive(v)

if __name__=='__main__':unittest.main()
