"""Fabricated negative controls only; these never qualify native execution."""
import copy
import hashlib
import json
from pathlib import Path
import sys
import unittest

ROOT=Path(__file__).resolve().parents[1]
sys.path[:0]=[str(ROOT),str(ROOT/'package')]
from state_contract import GROUPS,FLAGS,NUMBERS,CATEGORIES,validate_result
from compare import completion_join


def fixture():
    job=dict(mode='full',captureEvidence=False)
    value=dict(FLAGS,**NUMBERS,schema='gemma4_owned_mtp_state_qualification_v1',
        fixture='actual-owned-rectangular-attention-v1',passed=list(GROUPS),job=job,scopeSHA256='a'*64,
        guardObservationPolicy='gemma4_invocation_fresh_observation_v1',
        guardMetrics=dict(schema='gemma4_guard_wall_counters_v1',overflow=False,sameProcessClock=True,
            categoriesAreInclusive=True,extraOSReads=0,extraNativeEvaluations=0,observerOverheadIncludedInRequestTiming=True,
            records=[dict(category=x,count=1 if x in ('entryGuard','environmentGuard','osSnapshot','outerNativeFault') else 0,
                nanoseconds=1,nestedLogicalGuardNanoseconds=0) for x in CATEGORIES]))
    return value,job


class Contract(unittest.TestCase):
    def test_complete_fabricated_contract(self):
        value,job=fixture();validate_result(value,job,'a'*64)

    def test_missing_or_repeated_group(self):
        for groups in (GROUPS[:-1],GROUPS+[GROUPS[-1]],list(reversed(GROUPS))):
            value,job=fixture();value['passed']=groups
            with self.assertRaises(ValueError):validate_result(value,job)

    def test_counts_and_types(self):
        for key,wrong in [('actualPrefixCases',55),('maximumVerificationWidth',5),
                          ('nativeCacheBytesAfterRelease',False),('modeledSlidingLayers',24)]:
            value,job=fixture();value[key]=wrong
            with self.assertRaises(ValueError):validate_result(value,job)

    def test_no_model_or_transport_claim(self):
        for key in ('gemmaWeightsExecuted','assistantOrDistributedQualified','throughputMeasured','collectiveCreated'):
            value,job=fixture();value[key]=True
            with self.assertRaises(ValueError):validate_result(value,job)

    def test_job_and_scope_substitution(self):
        value,job=fixture()
        with self.assertRaises(ValueError):validate_result(value,job,'b'*64)
        other=copy.deepcopy(job);other['mode']='stage1'
        with self.assertRaises(ValueError):validate_result(value,other)

    def test_missing_guards_and_transport_use(self):
        for category in ('entryGuard','wireSendCompleted'):
            value,job=fixture()
            row=next(x for x in value['guardMetrics']['records'] if x['category']==category)
            row['count']=0 if category=='entryGuard' else 1
            with self.assertRaises(ValueError):validate_result(value,job)

    def test_terminal_bytes_and_role_join(self):
        raw=b'{"status":"completed"}\n';remote='/explicit/full'
        completion=dict(status='completed',mode='full',run=remote,terminalSHA256=hashlib.sha256(raw).hexdigest())
        completion_join(completion,raw,remote)
        with self.assertRaises(ValueError):completion_join(completion,raw+b' ',remote)
        with self.assertRaises(ValueError):completion_join(completion,raw,remote+'-replacement')
        completion['mode']='stage1'
        with self.assertRaises(ValueError):completion_join(completion,raw,remote)

    def test_extra_result_field_refused(self):
        value,job=fixture();value['tokensPerSecond']=47
        with self.assertRaises(ValueError):validate_result(value,job)


if __name__=='__main__':unittest.main()
