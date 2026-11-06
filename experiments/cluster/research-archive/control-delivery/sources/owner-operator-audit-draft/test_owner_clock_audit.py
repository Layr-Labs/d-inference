import copy
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import owner_clock_audit as a
import owner_dependencies as d
import owner_fixture as f
c=f.c


class OwnerAuditTests(unittest.TestCase):
    def setUp(self):self.case=f.case()
    def bad(self,edit,role='solo'):
        rows,full,owner=copy.deepcopy(self.case);edit(rows,full,owner)
        with self.assertRaises((ValueError,TypeError,KeyError)):a.check_records(rows,full,owner,role)
    def test_solo_positive_intervals(self):
        result=a.check_records(*self.case,'solo')
        self.assertEqual([x['elapsedNanoseconds'] for x in result['intervals']],[100]*4)
        self.assertEqual(result['traceSpanNanoseconds'],700)
        self.assertEqual(result['unclassifiedGapsWithinOwnerTraceNanoseconds'],300)
        self.assertEqual(result['unclassifiedParentTimeOutsideOwnerIntervalsNanoseconds'],600)
        self.assertFalse(result['baseOutputFullyValidated']);self.assertFalse(result['overheadIndependentlyMeasured'])
    def test_serial_pair(self):
        rows,full,owner=zip(f.case('rank0'),f.case('rank1'))
        result=a.check_pair(list(rows),list(full),list(owner));self.assertFalse(result['crossRankIntervalTotalsComputed'])
    def test_lookahead_pair(self):
        rows,full,owner=zip(f.case('rank0','prompt_lookahead_one_v1'),f.case('rank1','prompt_lookahead_one_v1'))
        result=a.check_pair(list(rows),list(full),list(owner));self.assertEqual(result['ranks'][0]['coarsePhaseEventCount'],204)
    def test_rank_clock_origins_never_aligned(self):
        rows,full,owner=zip(f.case('rank0',origin=10**12),f.case('rank1',origin=1))
        a.check_pair(list(rows),list(full),list(owner))
    def test_equal_times_accepted(self):
        rows,full,owner=self.case;time=owner['events'][0]['localUptimeNanoseconds'];f.retime(owner,[time]*8)
        result=a.check_records(rows,full,owner,'solo');self.assertEqual(result['selectedDisjointIntervalTotalNanoseconds'],0)
    def test_parent_edges_inclusive(self):
        rows,full,owner=self.case;low=owner['events'][0]['localUptimeNanoseconds']-100
        f.retime(owner,[low]*4+[low+1000]*4);a.check_records(rows,full,owner,'solo')
    def test_high_uint64_origin(self):a.check_records(*f.case(origin=c.U64-100000),'solo')
    def test_wrong_kind(self):self.bad(lambda r,p,o:o.update(kind='qwen_prefill_local_phase_trace'))
    def test_wrong_version(self):self.bad(lambda r,p,o:o.update(schemaVersion=2))
    def test_extra_trace_field(self):self.bad(lambda r,p,o:o.update(throughputTPS=800))
    def test_missing_trace_field(self):self.bad(lambda r,p,o:o.pop('includesRecorderOverhead'))
    def test_injected_owner_clock(self):self.bad(lambda r,p,o:o.update(clockSource='injected_test_clock'))
    def test_injected_coarse_clock(self):self.bad(lambda r,p,o:p.update(clockSource='injected_test_clock'))
    def test_capacity_changed(self):self.bad(lambda r,p,o:o.update(maximumEvents=9))
    def test_capacity_fraction(self):self.bad(lambda r,p,o:o.update(maximumEvents=8.0))
    def test_capacity_bool(self):self.bad(lambda r,p,o:o.update(maximumEvents=True))
    def test_false_kernel_scope(self):self.bad(lambda r,p,o:o.update(gpuKernelTimeAsserted=True))
    def test_false_check_exclusion(self):self.bad(lambda r,p,o:o.update(evaluationIntervalIncludesExistingErrorCheck=False))
    def test_false_independent_success(self):self.bad(lambda r,p,o:o.update(recorderIndependentlyVerifiesOuterSuccess=True))
    def test_wrong_role(self):self.bad(lambda r,p,o:o['identity'].update(role='rank0'))
    def test_geometry_hash_instead_of_recorded(self):
        self.bad(lambda r,p,o:o['identity'].update(requestFingerprint=c.request(r[1]['execution']['request'])['simple']))
    def test_changed_recorded_fingerprint(self):self.bad(lambda r,p,o:o['identity'].update(requestFingerprint='f'*64))
    def test_wrong_profile(self):self.bad(lambda r,p,o:o['identity'].update(profile='legacy_bounded_v1'))
    def test_wrong_selected_frame(self):self.bad(lambda r,p,o:o['identity'].update(frameSequence=6))
    def test_wrong_offset(self):self.bad(lambda r,p,o:o['identity'].update(tokenOffset=4096))
    def test_wrong_identity_count(self):self.bad(lambda r,p,o:o['identity'].update(tokenCount=32))
    def test_wrong_identity_frontier(self):self.bad(lambda r,p,o:o['identity'].update(committedFrontier=3584))
    def test_unknown_identity_field(self):self.bad(lambda r,p,o:o['identity'].update(frame=None))
    def test_float_selection(self):self.bad(lambda r,p,o:o['identity'].update(frameSequence=7.0))
    def test_missing_event(self):self.bad(lambda r,p,o:o['events'].pop())
    def test_extra_event(self):self.bad(lambda r,p,o:o['events'].append(copy.deepcopy(o['events'][-1])))
    def test_missing_event_timestamp(self):self.bad(lambda r,p,o:o['events'][0].pop('localUptimeNanoseconds'))
    def test_extra_event_frame(self):self.bad(lambda r,p,o:o['events'][0].update(frameSequence=7))
    def test_wrong_event_phase(self):self.bad(lambda r,p,o:o['events'][0].update(phase='rootStaging.begin'))
    def test_double_bookkeeping(self):self.bad(lambda r,p,o:o['events'][6].update(phase='validationCommit.end',committedTokens=4096))
    def test_wrong_event_count(self):self.bad(lambda r,p,o:o['events'][2].update(tokenCount=511))
    def test_early_commit_frontier(self):self.bad(lambda r,p,o:o['events'][6].update(committedTokens=4096))
    def test_uncommitted_final_frontier(self):self.bad(lambda r,p,o:o['events'][7].update(committedTokens=3584))
    def test_negative_event_frontier(self):self.bad(lambda r,p,o:o['events'][0].update(committedTokens=-1))
    def test_wrong_ordinal(self):self.bad(lambda r,p,o:o['events'][3].update(ordinal=4))
    def test_boolean_integer(self):self.bad(lambda r,p,o:o['events'][0].update(ordinal=False))
    def test_float_time(self):self.bad(lambda r,p,o:o['events'][0].update(localUptimeNanoseconds=float(o['events'][0]['localUptimeNanoseconds'])))
    def test_boolean_time(self):self.bad(lambda r,p,o:o['events'][0].update(localUptimeNanoseconds=True))
    def test_negative_time(self):self.bad(lambda r,p,o:o['events'][0].update(localUptimeNanoseconds=-1))
    def test_overflow_time(self):self.bad(lambda r,p,o:o['events'][7].update(localUptimeNanoseconds=2**64))
    def test_reversed_time(self):self.bad(lambda r,p,o:o['events'][4].update(localUptimeNanoseconds=o['events'][3]['localUptimeNanoseconds']-1))
    def test_wrong_span(self):self.bad(lambda r,p,o:o.update(traceSpanNanoseconds=701))
    def test_wrong_first(self):self.bad(lambda r,p,o:o.update(firstLocalUptimeNanoseconds=0))
    def test_wrong_last(self):self.bad(lambda r,p,o:o.update(lastLocalUptimeNanoseconds=0))
    def test_before_parent(self):
        self.bad(lambda r,p,o:f.retime(o,[x['localUptimeNanoseconds']-101 for x in o['events']]))
    def test_after_parent(self):
        self.bad(lambda r,p,o:f.retime(o,[x['localUptimeNanoseconds']+201 for x in o['events']]))
    def test_missing_parent_phase(self):self.bad(lambda r,p,o:p['events'].pop(17))
    def test_coarse_event_frontier_changed(self):self.bad(lambda r,p,o:p['events'][17].update(committedTokens=0))
    def test_wrong_stdout_ready_history(self):self.bad(lambda r,p,o:r[0].update(recordedRequestFingerprint='e'*64))
    def test_failed_outer_retirement(self):self.bad(lambda r,p,o:r[1].update(allRequestStateRetired=False))
    def test_changed_native_actions_with_matching_coarse_phase(self):
        self.case=f.case('rank0')
        def edit(r,p,o):r[1]['execution']['actions'][5]['action']='fake';p['events'][5]['phase']='fake'
        self.bad(edit,'rank0')
    def test_pair_cross_cohort(self):
        rows,full,owner=zip(f.case('rank0'),f.case('rank1',epoch='102132435465768798a9bacbdcedfe0f'))
        with self.assertRaises(ValueError):a.check_pair(list(rows),list(full),list(owner))
    def test_pair_swapped(self):
        rows,full,owner=zip(f.case('rank1'),f.case('rank0'))
        with self.assertRaises(ValueError):a.check_pair(list(rows),list(full),list(owner))
    def test_duplicate_json(self):
        with self.assertRaises(ValueError):c.parse(b'{"identity":{"role":"solo","role":"solo"}}')
    def test_nonfinite_json(self):
        with self.assertRaises(ValueError):c.parse(b'{"x":1e309}')
    def test_fractional_json_integer(self):
        rows,full,owner=self.case;raw=c.canonical(owner).replace(b'"maximumEvents":8',b'"maximumEvents":8e0')
        with self.assertRaises(ValueError):a.check_records(rows,full,c.parse(raw),'solo')
    def test_negative_zero_integer(self):
        rows,full,owner=self.case;raw=c.canonical(owner).replace(b'"ordinal":0',b'"ordinal":-0',1)
        with self.assertRaises(ValueError):a.check_records(rows,full,c.parse(raw),'solo')
    def test_dependency_tampered(self):
        with patch.dict(d.PINS,{next(iter(d.PINS)):'0'*64}),self.assertRaises(ValueError):d.verify_pins()
    def test_path_api_positive(self):
        with tempfile.TemporaryDirectory() as name:
            p=Path(name);stdout=p/'stdout.jsonl';phase=p/'phase.json';owner=p/'owner.json';r,t,o=self.case
            stdout.write_bytes(b'\n'.join(c.canonical(x) for x in r)+b'\n');phase.write_bytes(c.canonical(t));owner.write_bytes(c.canonical(o))
            result=a.validate_solo(stdout,phase,owner);self.assertTrue(result['frozenInputsUnchanged']);self.assertEqual(len(result['inputs']),3)
    def test_owner_file_bound(self):
        with tempfile.TemporaryDirectory() as name:
            p=Path(name);stdout=p/'stdout.jsonl';phase=p/'phase.json';owner=p/'owner.json';r,t,o=self.case
            stdout.write_bytes(b'\n'.join(c.canonical(x) for x in r));phase.write_bytes(c.canonical(t));owner.write_bytes(b' '*(a.MAX_OWNER_BYTES+1))
            with self.assertRaises(ValueError):a.validate_solo(stdout,phase,owner)
    def test_duplicate_paths(self):
        with self.assertRaises(ValueError):a.validate_solo('same','same','same')
    def test_numeric_scope_remains_separate(self):
        rows,full,owner=self.case;rows[1]['execution']['finalState']={'fabricated':'not validated here'}
        self.assertFalse(a.check_records(rows,full,owner,'solo')['baseOutputFullyValidated'])

if __name__=='__main__':unittest.main(verbosity=2)
