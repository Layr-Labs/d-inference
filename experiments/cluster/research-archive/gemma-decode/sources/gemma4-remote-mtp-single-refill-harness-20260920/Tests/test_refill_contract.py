"""Pure reader controls; no child process, native library, or GPU."""
import importlib.util,sys,types,unittest
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
s=importlib.util.spec_from_file_location('refill_prepare',ROOT/'prepare.py');prep=importlib.util.module_from_spec(s);s.loader.exec_module(prep)

class RefillContractTests(unittest.TestCase):
 @classmethod
 def setUpClass(cls):
  cls.spec,projects,cls.parent,cls.old,cls.description,cls.union,cls.expected=prep.verify()
  for name,rel in [('binding_common','package/binding_common.py'),('refill_contract','package/refill_contract.py')]:
   m=types.ModuleType(name);exec(compile(projects['remote'][rel],rel,'exec'),m.__dict__);sys.modules[name]=m
  cls.c=sys.modules['refill_contract']
 def wrapper(self,policy=None):
  value={x:'fixture' for x in self.c.FIELDS}
  if policy is not None:value['refillPolicy']=policy
  return value
 def refusal(self,fn,*args):
  with self.assertRaises((ValueError,AssertionError,RuntimeError)):fn(*args)
 def test_default_depth_two_unchanged(self):
  w=self.wrapper();self.assertEqual(self.c.validate_wrapper(w,{'maximumDraftTokens':2}),'paired_v1');self.assertEqual(self.c.scope_components(w,{'maximumDraftTokens':2}),[])
 def test_explicit_single_depth_one(self):
  w=self.wrapper(self.c.SINGLE);self.assertEqual(self.c.validate_wrapper(w,{'maximumDraftTokens':1}),self.c.SINGLE)
 def test_single_depth_two_refuses(self):self.refusal(self.c.validate_wrapper,self.wrapper(self.c.SINGLE),{'maximumDraftTokens':2})
 def test_boolean_depth_refuses(self):self.refusal(self.c.validate_wrapper,self.wrapper(self.c.SINGLE),{'maximumDraftTokens':True})
 def test_explicit_null_refuses(self):
  w=self.wrapper();w['refillPolicy']=None;self.refusal(self.c.validate_wrapper,w,{'maximumDraftTokens':1})
 def test_explicit_default_and_unknown_refuse(self):
  for policy in ('paired_v1','single','single_for_depth_one_v2'):self.refusal(self.c.validate_wrapper,self.wrapper(policy),{'maximumDraftTokens':1})
 def test_unknown_wrapper_field_refuses(self):
  w=self.wrapper();w['snapshotPolicy']='anything';self.refusal(self.c.validate_wrapper,w,{'maximumDraftTokens':1})
 def test_metadata_exact_limits(self):
  w=self.wrapper(self.c.SINGLE);l={'maximumDraftTokens':1};v=dict(producerRefillPolicy=self.c.SINGLE,maximumProducerRefillGrant=1,maximumProducerLookaheadGrant=2)
  self.c.validate_refill_metadata(v,w,l)
  for key,value in [('maximumProducerRefillGrant',2),('maximumProducerRefillGrant',True),('maximumProducerLookaheadGrant',1),('producerRefillPolicy','paired_v1')]:
   bad=dict(v);bad[key]=value;self.refusal(self.c.validate_refill_metadata,bad,w,l)
 def test_legacy_metadata_cannot_claim_override(self):
  self.c.validate_refill_metadata({},self.wrapper(),{'maximumDraftTokens':2})
  for key in self.c.META:self.refusal(self.c.validate_refill_metadata,{key:1},self.wrapper(),{'maximumDraftTokens':1})
 def test_scope_exact_chosen_policy(self):
  self.assertEqual(self.c.scope_components(self.wrapper(self.c.SINGLE),{'maximumDraftTokens':1}),['producerRefillPolicy='+self.c.SINGLE,'producerLookaheadGrant=2'])
 def test_old_build_paths_refuse(self):
  self.refusal(prep.bind,Path(self.old['plannedBuild']),Path(self.old['plannedSources']),self.spec,self.parent,self.old,self.description,self.union,self.expected)
 def test_missing_explicit_metadata_refuses(self):
  self.refusal(self.c.validate_refill_metadata,{},self.wrapper(self.c.SINGLE),{'maximumDraftTokens':1})
if __name__=='__main__':unittest.main()
