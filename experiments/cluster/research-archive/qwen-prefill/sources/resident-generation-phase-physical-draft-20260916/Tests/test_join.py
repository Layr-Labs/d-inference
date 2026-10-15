"""Fabricated joins, no model/remote or actual physical evidence reads."""
import copy,sys,unittest
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from phase_schema_fixture import fixture
from capacity import derive,native_bound
from validate_run import join_reports

def case(policy='oneChunkLookahead'):
    pairs=[fixture(rank,policy) for rank in [0,1]]
    reports=[p[0] for p in pairs];expected=[p[1] for p in pairs]
    host=dict(reports[0]['budget']);del host['totalReservedBytes'];cap=derive(host,policy)
    for rank,r in enumerate(reports):r['budget']=dict(host,totalReservedBytes=cap['ranks'][rank]['totalReservedBytes'])
    obs=dict(rankReadinessCapacityBytes=[r['totalReservedBytes'] for r in cap['ranks']],admittedReservedBytes=cap['pairCapacityBytes'])
    return reports,expected,dict(capacities=cap,controller=dict(phaseReservationObservation=obs))
class JoinTests(unittest.TestCase):
    def test_both_policies(self):
        for p in ['serial','oneChunkLookahead']:
            r,e,x=case(p);self.assertEqual([z['rank'] for z in join_reports(r,e,x)],[0,1])
    def test_rank_capacity_mismatch(self):
        r,e,x=case();x['controller']['phaseReservationObservation']['rankReadinessCapacityBytes'][0]-=1
        with self.assertRaises(ValueError):join_reports(r,e,x)
    def test_ack_sum_mismatch(self):
        r,e,x=case();x['controller']['phaseReservationObservation']['admittedReservedBytes']-=1
        with self.assertRaises(ValueError):join_reports(r,e,x)
    def test_uncharged_host(self):
        r,e,x=case();r[1]['budget']['totalReservedBytes']-=r[1]['budget']['requiredHostReservationBytes']
        with self.assertRaises(ValueError):join_reports(r,e,x)
    def test_foreign_clock_offset_is_not_subtracted(self):
        r,e,x=case();before=join_reports(r,e,x)
        for v in r[1]['events']:v['localUptimeNanoseconds']+=2**40
        for k in ['firstLocalUptimeNanoseconds','lastLocalUptimeNanoseconds']:r[1][k]+=2**40
        self.assertEqual(join_reports(r,e,x),before)
    def test_partial_retirement(self):
        r,e,x=case();r[1]['execution']['bothRequestStatesRetired']=False
        with self.assertRaises(ValueError):join_reports(r,e,x)
    def test_chain_mismatch(self):
        r,e,x=case();r[1]['execution']['tokenChainSHA256']='c'*64
        with self.assertRaises(ValueError):join_reports(r,e,x)
    def test_page_reuse_bound(self):
        self.assertEqual(native_bound(4),7);self.assertEqual(native_bound(16384),32767);self.assertEqual(native_bound(16385),65535)
if __name__=='__main__':unittest.main()
