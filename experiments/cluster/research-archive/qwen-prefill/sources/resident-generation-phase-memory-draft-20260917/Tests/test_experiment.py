"""Fabricated host/capacity/phase evidence only; no model, compiler or remote IO."""
import copy,sys,unittest
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'Experiment'))
from capacity import derive,state,native_bound
from validate_run import join_reports
from test_memory_schema import fixture

def host_budget():
    # Synthetic host rounding only; native binding requires actual CPU output.
    b=dict(maximumEvents=544,eventLogicalBytes=47872,eventAllocationBytes=65536,
        memoryLogicalBytes=102400,memoryAllocationBytes=131072,encodedResultAllocationBytes=1052672,
        encodingScratchAllowanceBytes=2101248,metadataAllowanceBytes=20480)
    b['requiredHostReservationBytes']=sum(b[k] for k in ['eventAllocationBytes','memoryAllocationBytes',
        'encodedResultAllocationBytes','encodingScratchAllowanceBytes','metadataAllowanceBytes'])
    return b

def pair(policy='serial'):
    host=host_budget();cap=derive(host,policy);reports=[];expected=[]
    for rank in [0,1]:
        report,wanted=fixture(rank,policy);report['budget']=dict(host,totalReservedBytes=cap['ranks'][rank]['requestReservationBytes'])
        reports.append(report);expected.append(wanted)
    external=dict(capacities=cap,controller=dict(phaseReservationObservation=dict(
        rankReadinessCapacityBytes=[x['readyCapacityBytes'] for x in cap['ranks']],
        admittedReservedBytes=sum(x['requestReservationBytes'] for x in cap['ranks']))))
    return reports,expected,external

class ExperimentTests(unittest.TestCase):
    def test_c512_ready_ceiling_remains_above_c256_request(self):
        for policy in ['serial','oneChunkLookahead']:
            rows=derive(host_budget(),policy)['ranks']
            for row in rows:
                self.assertGreater(row['readyCapacityBytes'],row['requestReservationBytes'])
                self.assertEqual(row['readyCapacityBytes']-row['requestReservationBytes'],
                    2*(native_bound(512*5120*4)-native_bound(256*5120*4)))
                self.assertGreaterEqual(row['loadedGuardRequiredActualFreeBytes'],6*1024**3)
                self.assertGreaterEqual(row['requestRequiredActualFreeBytes'],6*1024**3)

    def test_lookahead_directional_buffer_is_not_halved_or_applied_to_rank1(self):
        a=derive(host_budget(),'serial')['ranks'];b=derive(host_budget(),'oneChunkLookahead')['ranks']
        self.assertEqual(b[0]['requestReservationBytes']-a[0]['requestReservationBytes'],
            native_bound(256*5120*2)+256*5120*2+65536)
        self.assertEqual(b[1]['requestReservationBytes']-a[1]['requestReservationBytes'],65536)
        self.assertEqual(a[0]['requestStateBytes'],a[1]['requestStateBytes'])

    def test_actual_ready_and_reservation_are_independently_joined(self):
        for policy in ['serial','oneChunkLookahead']:
            reports,wanted,external=pair(policy)
            self.assertEqual([x['rank'] for x in join_reports(reports,wanted,external)],[0,1])
            bad=copy.deepcopy(external)
            bad['controller']['phaseReservationObservation']['rankReadinessCapacityBytes']=[x['requestReservationBytes'] for x in bad['capacities']['ranks']]
            with self.assertRaises(ValueError):join_reports(reports,wanted,bad)
            bad=copy.deepcopy(external)
            bad['controller']['phaseReservationObservation']['admittedReservedBytes']=sum(x['readyCapacityBytes'] for x in bad['capacities']['ranks'])
            with self.assertRaises(ValueError):join_reports(reports,wanted,bad)

    def test_swapped_or_undercharged_host_and_rank_evidence_refused(self):
        reports,wanted,external=pair('oneChunkLookahead')
        bad=copy.deepcopy(external);bad['capacities']['ranks'].reverse()
        with self.assertRaises(ValueError):join_reports(reports,wanted,bad)
        bad=copy.deepcopy(reports);bad[0]['budget']['memoryAllocationBytes']-=1
        with self.assertRaises(ValueError):join_reports(bad,wanted,external)
        for change in ['host','bool','cap','memory','old']:
            b=host_budget()
            if change=='host':b['requiredHostReservationBytes']-=1
            if change=='bool':b['memoryAllocationBytes']=True
            if change=='cap':b['encodedResultAllocationBytes']=256*1024
            if change=='memory':b['memoryAllocationBytes']=1
            if change=='old':b['maximumEvents']=288
            with self.subTest(change=change),self.assertRaises(ValueError):derive(b,'serial')

if __name__=='__main__':unittest.main()
