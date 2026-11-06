"""Synthetic metadata controls for the exact installed description validator."""
import copy,sys,unittest
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'proposed/local/package'))
from description_contract import validate_description_targets

def fixture(output=128,mode='full'):
    job=dict(outputCount=output,mode=mode)
    rows=[]
    for name in (['full','stage0','stage1'] if output==16 else ['full']):
        rows.append(dict(target=name,selectedTensorCount=1339,selectedBytes=1,namedNativeLogicalBytes=1,
            hostEvidenceBytes=0,extraPrefillNativeBytes=0,extraPrefillHostBytes=0,stateLogicalBytes=1,
            minimumFreeBeforeLoadLogicalLowerBound=1))
    return dict(schema='gemma4_resident_benchmark_capability_v1',job=job,metadataOnly=True,runtimeExecutionAuthorized=False,targets=rows),job

class Description(unittest.TestCase):
    def reject(self,change,output=128):
        value,job=fixture(output);change(value,job)
        with self.assertRaises((AssertionError,KeyError)):validate_description_targets(value,job)
    def test_o16_retains_all_three_targets(self):
        for mode in ('full','stage0','stage1'):
            value,job=fixture(16,mode);self.assertEqual(validate_description_targets(value,job),['full','stage0','stage1'])
    def test_o128_full_is_one_target(self):
        value,job=fixture();self.assertEqual(validate_description_targets(value,job),['full'])
    def test_o128_stage_and_extra_targets_refuse(self):
        self.reject(lambda v,j:j.update(mode='stage0'))
        self.reject(lambda v,j:v['targets'].append(dict(v['targets'][0],target='stage0')))
    def test_missing_reordered_duplicate_targets_refuse(self):
        self.reject(lambda v,j:v['targets'].pop(),16)
        self.reject(lambda v,j:v['targets'].reverse(),16)
        self.reject(lambda v,j:v['targets'][1].update(target='full'),16)
    def test_envelope_flags_schema_refuse(self):
        self.reject(lambda v,j:j.update(outputCount=129))
        self.reject(lambda v,j:v.update(metadataOnly=1))
        self.reject(lambda v,j:v.update(runtimeExecutionAuthorized=True))
        self.reject(lambda v,j:v.update(schema='other'))
    def test_integer_budget_fields_remain_strict(self):
        for number in (True,-1,2**64,1.0):self.reject(lambda v,j,n=number:v['targets'][0].update(selectedBytes=n))
        self.reject(lambda v,j:v['targets'][0].update(selectedTensorCount=0))
        self.reject(lambda v,j:v['targets'][0].update(extraUnknown=0))
    def test_installed_metadata_calls_the_helper(self):
        root=Path(__file__).resolve().parents[1]
        text=(root/'proposed/local/remote_metadata.py').read_text()
        self.assertIn('from description_contract import validate_description_targets',text)
        self.assertEqual(text.count('validate_description_targets(result,job)'),1)
        self.assertIn('gemma4-local-mtp-o128-20260920-v3',text)
if __name__=='__main__':unittest.main()
