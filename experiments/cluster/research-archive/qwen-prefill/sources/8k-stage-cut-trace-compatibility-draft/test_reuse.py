"""Synthetic cut12 rank rows with unchanged frozen phase/owner auditors."""
import copy
import hashlib
import json
from pathlib import Path
import sys
import unittest

ROOT=Path(__file__).resolve().parent.parent
for folder in ['owner-operator-audit-draft','8k-stage-cut-rank-audit-draft']:
    sys.path.insert(0,str(ROOT/folder))
for name,pin in [('owner-operator-audit-draft/manifest.json','01564e53ceb50ac482245f13f2b068c90b90ec8977815638e701fe82cd5e30e8'),
                 ('phase-clock-audit-draft/manifest.json','a540ab7a9ddf115ea3e34712fe152dbcb21d532f03a3e0749b6fd347645e6176'),
                 ('8k-stage-cut-rank-audit-draft/manifest.json','ce07ec46b650a3d59d7bffd4926b8372b2e30f28fa944975f058b82fa4d3cc55')]:
    path=ROOT/name;raw=path.read_bytes();assert hashlib.sha256(raw).hexdigest()==pin
    members=json.loads(raw)['files']
    if type(members) is dict: members=[dict(item,path=name) for name,item in members.items()]
    for item in members:
        member=Path(item['path']);member=member if member.is_absolute() else path.parent/member
        b=member.read_bytes();assert hashlib.sha256(b).hexdigest()==item['sha256']

import owner_clock_audit as owner
import owner_dependencies
import owner_fixture
import cut12_rank_fixture
import qwen_long_prefill_rank_cut12_audit as numeric

phase,c=owner_dependencies.phase()


def case(policy='serial_v1'):
    x=cut12_rank_fixture.fixture(policy)
    rows=copy.deepcopy(x['ranks']);full=[];selected=[]
    for index,origin in enumerate([10**12,1]):
        _,coarse,fine=owner_fixture.case('rank'+str(index),policy,origin=origin,epoch=x['epoch'])
        full.append(coarse);selected.append(fine)
    rows[0][1]['execution']['timing']=owner_fixture.f.timing(full[0],'rank0')
    return x,rows,full,selected


class ReuseTests(unittest.TestCase):
    def test_serial_full_numerical_fixture_and_unchanged_auditors(self):
        x,rows,full,selected=case()
        result=numeric.check_rank_pair(rows,x['baseline'],x['prompt'],x['promptSHA'],x['epoch'],x['policy'])
        self.assertEqual([len(r[1]['execution']['finalDigest']['finalState']['entries']) for r in rows],[27,45])
        coarse=phase.check_pair(rows,full);fine=owner.check_pair(rows,full,selected)
        self.assertEqual([r['eventCount'] for r in coarse['ranks']],[204,235])
        self.assertEqual([r['ownerEventCount'] for r in fine['ranks']],[8,8])
        for r in coarse['ranks']+fine['ranks']:
            self.assertEqual(r['agreementFingerprint'],result['agreementFingerprint'])
            self.assertEqual(r['recordedRequestFingerprint'],result['recordedRequestFingerprint'])
            self.assertFalse(r['baseOutputFullyValidated'])
        self.assertFalse(fine['crossRankIntervalTotalsComputed'])

    def test_lookahead_is_still_locally_compatible(self):
        x,rows,full,selected=case('prompt_lookahead_one_v1')
        self.assertEqual(numeric.check_rank_pair(rows,x['baseline'],x['prompt'],x['promptSHA'],x['epoch'],x['policy'])['preparedAheadFrames'],[15,0])
        self.assertEqual(owner.check_pair(rows,full,selected)['status'],'passed')

    def test_changed_recorded_identity_or_frame_refused(self):
        for key,value in [('requestFingerprint','0'*64),('frameSequence',6),('committedFrontier',8192)]:
            _,rows,full,selected=case();selected[0]['identity'][key]=value
            with self.subTest(key=key),self.assertRaises(ValueError):owner.check_pair(rows,full,selected)

    def test_changed_actions_and_outside_parent_refused(self):
        _,rows,full,selected=case();rows[0][1]['execution']['actions'][5]['action']='other'
        full[0]['events'][5]['phase']='other'
        with self.assertRaises(ValueError):owner.check_pair(rows,full,selected)
        _,rows,full,selected=case()
        owner_fixture.retime(selected[1],[e['localUptimeNanoseconds']+1001 for e in selected[1]['events']])
        with self.assertRaises(ValueError):owner.check_pair(rows,full,selected)

    def test_plan_is_explicitly_outside_trace_qualification(self):
        x,rows,full,selected=case()
        # Coherently change only the agreement's plan commitment. The trace
        # validates its own metadata but cannot establish selected model assets.
        for stream in rows:
            for record in stream:
                agreement=record['agreement'];agreement['planFingerprint']='0'*64
                record['agreementFingerprint']=c.sha(b'qwen-profiled-prefill-start-agreement-v1\n'+c.canonical(agreement))
            stream[1]['execution']['agreementFingerprint']=stream[1]['agreementFingerprint']
        self.assertEqual(owner.check_pair(rows,full,selected)['status'],'passed')
        with self.assertRaises(ValueError):numeric.check_rank_pair(rows,x['baseline'],x['prompt'],x['promptSHA'],x['epoch'],x['policy'])

    def test_unvalidated_numerical_fields_stay_separate(self):
        x,rows,full,selected=case();rows[1][1]['execution']['finalDigest']={'opaque':'deliberately invalid'}
        self.assertEqual(owner.check_pair(rows,full,selected)['status'],'passed')
        with self.assertRaises((ValueError,KeyError)):numeric.check_rank_pair(rows,x['baseline'],x['prompt'],x['promptSHA'],x['epoch'],x['policy'])


if __name__=='__main__':unittest.main(verbosity=2)
