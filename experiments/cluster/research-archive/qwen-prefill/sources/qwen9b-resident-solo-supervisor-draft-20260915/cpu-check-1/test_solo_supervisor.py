from pathlib import Path
import copy
import json
import sys
import tempfile
import unittest
from binding_common import canonical
from solo_contract import admitted,expected_identity,report
from solo_fixture import receipts
from solo_inputs import native_spec,validate_job
from run_solo import serve
from worker_contract import WorkerSpec

BASE=Path(__file__).resolve().parent


class Pins:
    def recheck(self):pass


class SoloChecks(unittest.TestCase):
    def setUp(self):
        self.job=json.loads((BASE/'job.json').read_bytes())
        self.tokens=json.loads((BASE/'inputs/prompt.ids.json').read_bytes())
        self.ids=json.loads((BASE/'inputs/expected-token-ids.json').read_bytes())
        self.expected=expected_identity(self.job,self.tokens,self.ids)
        self.first,self.final=receipts(self.expected)

    def validate(self,value):
        return report(canonical(value),self.expected,self.first,1,Path(self.job['deployment']))

    def test_valid_contract_and_exact_argv(self):
        self.assertEqual(admitted(canonical(self.first),self.expected),self.first)
        self.assertEqual(self.validate(self.final),self.final)
        validate_job(self.job);spec=native_spec(self.job)
        self.assertEqual(len(spec.argv),29)
        self.assertEqual(spec.argv[1:3],('--mode','qwen-resident-solo-generation'))
        self.assertEqual(spec.argv[-2:],('--expected-token-ids-sha256',self.job['expected_sha256']))

    def test_identity_or_schedule_substitution(self):
        for key,value in [('warmupCount',0),('freshRequestsAdmitted',3),('mtpEnabled',True),('prefixReuse',True)]:
            bad=copy.deepcopy(self.final);bad[key]=value
            with self.assertRaises(ValueError):self.validate(bad)
        for field,value in [('stage_cut',16),('registered_model','registered_qwen38_27b'),('prompt_count',4096),('stop_token_ids',[19])]:
            with self.assertRaises(ValueError):validate_job(dict(self.job,**{field:value}))

    def test_uuid_reuse_or_fingerprint(self):
        for change in ('duplicate','fingerprint'):
            bad=copy.deepcopy(self.first)
            if change=='duplicate':bad['requestIDs'][1]=bad['requestIDs'][0]
            else:bad['requestFingerprints'][2]='b'*64
            with self.assertRaises(ValueError):admitted(canonical(bad),self.expected)

    def test_dispatch_requires_actual_warmup_and_disabled_measurement(self):
        for section,key,value in [('warmupDispatch','nativeDecodeCalls',3047),('warmupDispatch','operationsFallbackCalls',1),
                                  ('','measuredRequestDispatchObservationEnabled',True),('','fusedProjectionLayers',23)]:
            bad=copy.deepcopy(self.final);target=bad['kernelEligibility']
            if section:target=target[section]
            target[key]=value
            with self.assertRaises(ValueError):self.validate(bad)

    def test_token_count_value_frontier_and_capture_refused(self):
        for key,value in [('selectedTokenIDs',self.ids[:-1]),('selectedTokenIDs',[0]+self.ids[1:]),
                          ('committedTokens',8320),('stateSnapshotsCaptured',True),('fullVocabularyRowsCaptured',True)]:
            bad=copy.deepcopy(self.final);bad['requests'][2]['execution'][key]=value
            with self.assertRaises(ValueError):self.validate(bad)

    def test_time_order_denominator_and_request_overlap_refused(self):
        for change in ('count','order','denominator','overlap','nan'):
            bad=copy.deepcopy(self.final);t=bad['requests'][2]['execution']['timing']
            if change=='count':t['selectedTokenNanoseconds'].pop()
            elif change=='order':t['selectedTokenNanoseconds'][5]=t['selectedTokenNanoseconds'][3]
            elif change=='denominator':t['decodeTokensPerSecond']=128/t['decodeSeconds']
            elif change=='overlap':t['requestStartNanoseconds']=1
            else:t['prefillSeconds']=float('nan')
            with self.assertRaises(ValueError):self.validate(bad)

    def test_resource_and_model_retirement_refused(self):
        for change in ('free','model','state','layout','pid'):
            bad=copy.deepcopy(self.final)
            if change=='free':bad['resources']['minimumActualFreeBytes']=6*1024**3-1
            elif change=='model':bad['modelReleased']=False
            elif change=='state':bad['requests'][3]['execution']['allRequestStateRetired']=False
            elif change=='layout':bad['sourceLoad']['parameterLayoutSHA256']='c'*64
            else:bad['runtime']['processID']=2
            with self.assertRaises(ValueError):self.validate(bad)

    def child(self,mode,wanted,timeout=4):
        with tempfile.TemporaryDirectory(prefix='solo-parent-') as name:
            root=Path(name);run=root/'run';run.mkdir()
            fixture=root/'fixture.json';fixture.write_bytes(canonical([self.first,self.final]))
            spec=WorkerSpec((sys.executable,'-B',str(BASE/'fabricated_solo.py'),str(fixture),mode),
                {'PATH':'/usr/bin:/bin','LANG':'C'},'solo',None)
            phases=[]
            code=serve(self.job,spec,self.tokens,self.ids,run,lambda phase:phases.append(phase),Pins(),timeout)
            result=json.loads((run/'terminal.json').read_bytes())
            self.assertEqual(code,wanted,result)
            self.assertTrue(result['nativeLeaderReaped'])
            self.assertTrue(result['ownedGroupFenceComplete'])
            self.assertTrue(result['sourceInputsUnchanged'])
            self.assertIn('postflight',phases)
            return result

    def test_actual_child_exact_two_records_and_eof(self):
        result=self.child('success',0)
        self.assertEqual(result['nativeExitCodes'],[0]);self.assertTrue(result['outputComplete'])

    def test_actual_child_missing_extra_or_nonzero_fail(self):
        for mode in ('missing','extra','nonzero'):
            result=self.child(mode,1)
            self.assertEqual(result['status'],'failed')

    def test_actual_stalled_child_is_fenced(self):
        result=self.child('stall',1,0.25)
        self.assertNotEqual(result['nativeExitCodes'],[0])


if __name__=='__main__':unittest.main()
