import copy
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import phase_clock_audit as a
import phase_contract as c
import phase_fixture as f


class PhaseAuditTests(unittest.TestCase):
    def setUp(self):self.rows,self.trace=f.solo()
    def bad(self,mutate,role='solo'):
        rows,t=copy.deepcopy((self.rows,self.trace));mutate(rows,t)
        with self.assertRaises((ValueError,TypeError,KeyError)):a.check_records(rows,t,role)
    def test_solo_positive_exact_spans(self):
        result=a.check_records(self.rows,self.trace,'solo')
        self.assertEqual(result['eventCount'],41)
        group=result['intervalGroups'][0]
        self.assertEqual(group['intervalCount'],16);self.assertEqual(group['totalNanoseconds'],16000)
        self.assertEqual([x['elapsedNanoseconds'] for x in group['intervals']],[1000]*16)
        self.assertFalse(result['baseOutputFullyValidated']);self.assertTrue(result['numericalValidationRequiredSeparately'])
    def test_serial_positive(self):
        rs,ts=zip(f.rank(0),f.rank(1));result=a.check_pair(list(rs),list(ts))
        self.assertEqual([x['eventCount'] for x in result['ranks']],[204,235])
    def test_lookahead_positive(self):
        rs,ts=zip(f.rank(0,'prompt_lookahead_one_v1'),f.rank(1,'prompt_lookahead_one_v1'))
        r=a.check_pair(list(rs),list(ts));self.assertEqual(r['ranks'][0]['schedulingPolicy'],'prompt_lookahead_one_v1')
    def test_rank_clocks_unaligned_accepted(self):
        r0,t0=f.rank(0,origin=10**12);r1,t1=f.rank(1,origin=7)
        result=a.check_pair([r0,r1],[t0,t1]);self.assertFalse(result['crossRankIntervalTotalsComputed'])
    def test_equal_adjacent_timestamps_accepted(self):
        self.trace['events'][4]['localUptimeNanoseconds']=self.trace['events'][3]['localUptimeNanoseconds']
        r=a.check_records(self.rows,self.trace,'solo');self.assertEqual(r['intervalGroups'][0]['intervals'][0]['elapsedNanoseconds'],0)
    def test_uint64_high_origin(self):
        rows,t=f.solo(origin=c.U64-100000);a.check_records(rows,t,'solo')
    def test_geometry_only_identity_rejected(self):
        self.bad(lambda r,t:t['identity'].update(requestFingerprint=c.request(r[1]['execution']['request'])['simple']))
    def test_wrong_role(self):self.bad(lambda r,t:t['identity'].update(role='rank0'))
    def test_wrong_profile(self):self.bad(lambda r,t:t['identity'].update(profile='legacy_bounded_v1'))
    def test_unknown_identity_field(self):self.bad(lambda r,t:t['identity'].update(extra=1))
    def test_injected_clock(self):self.bad(lambda r,t:t.update(clockSource='injected_test_clock'))
    def test_unknown_trace_field(self):self.bad(lambda r,t:t.update(wallTime=4))
    def test_scope_flag(self):self.bad(lambda r,t:t.update(gpuOverlapAsserted=True))
    def test_no_retirement_proof(self):self.bad(lambda r,t:t.update(recorderIndependentlyVerifiesRequestRetirement=True))
    def test_wrong_capacity(self):self.bad(lambda r,t:t.update(maximumEvents=1024))
    def test_capacity_boolean(self):self.bad(lambda r,t:t.update(maximumEvents=True))
    def test_capacity_float(self):self.bad(lambda r,t:t.update(maximumEvents=512.0))
    def test_missing_event(self):self.bad(lambda r,t:t['events'].pop(4))
    def test_duplicate_event(self):self.bad(lambda r,t:t['events'].insert(4,t['events'][4]))
    def test_phase_changed(self):self.bad(lambda r,t:t['events'][4].update(phase='prefill.begin'))
    def test_frame_omission(self):self.bad(lambda r,t:t['events'][4].pop('frameSequence'))
    def test_frame_null(self):self.bad(lambda r,t:t['events'][0].update(frameSequence=None))
    def test_frame_boolean(self):self.bad(lambda r,t:t['events'][4].update(frameSequence=False))
    def test_frame_float(self):self.bad(lambda r,t:t['events'][4].update(frameSequence=0.0))
    def test_ordinal_changed(self):self.bad(lambda r,t:t['events'][4].update(ordinal=5))
    def test_frontier_changed(self):self.bad(lambda r,t:t['events'][4].update(committedTokens=1024))
    def test_frontier_boolean(self):self.bad(lambda r,t:t['events'][0].update(committedTokens=False))
    def test_unknown_event_field(self):self.bad(lambda r,t:t['events'][4].update(complete=True))
    def test_clock_reversal(self):self.bad(lambda r,t:t['events'][4].update(localUptimeNanoseconds=1))
    def test_negative_clock(self):self.bad(lambda r,t:t['events'][0].update(localUptimeNanoseconds=-1))
    def test_overflow_clock(self):self.bad(lambda r,t:t['events'][4].update(localUptimeNanoseconds=2**64))
    def test_float_clock(self):self.bad(lambda r,t:t['events'][4].update(localUptimeNanoseconds=1e9+4000))
    def test_boolean_clock(self):self.bad(lambda r,t:t['events'][0].update(localUptimeNanoseconds=True))
    def test_span_changed(self):self.bad(lambda r,t:t.update(traceSpanNanoseconds=40001))
    def test_first_changed(self):self.bad(lambda r,t:t.update(firstLocalUptimeNanoseconds=999999999))
    def test_last_changed(self):self.bad(lambda r,t:t.update(lastLocalUptimeNanoseconds=1000040001))
    def test_coherent_shift_without_main_clock(self):
        def edit(r,t):
            for e in t['events']:e['localUptimeNanoseconds']+=100000
            t['firstLocalUptimeNanoseconds']+=100000;t['lastLocalUptimeNanoseconds']+=100000
        self.bad(edit)
    def test_solo_start_after_created(self):
        def edit(r,t):
            clock=r[1]['execution']['timing'];clock['startUptimeNanoseconds']+=1000
            clock['elapsedNanoseconds']=clock['stopUptimeNanoseconds']-clock['startUptimeNanoseconds']
            clock['promptTokensPerFirstTokenSecond']=8192e9/clock['elapsedNanoseconds']
        self.bad(edit)
    def test_solo_stop_after_selection(self):
        def edit(r,t):
            clock=r[1]['execution']['timing'];clock['stopUptimeNanoseconds']+=1000
            clock['elapsedNanoseconds']+=1000;clock['postStopThroughRequestCloseNanoseconds']-=1000
            clock['promptTokensPerFirstTokenSecond']=8192e9/clock['elapsedNanoseconds']
        self.bad(edit)
    def test_solo_close_after_marker(self):
        self.bad(lambda r,t:r[1]['execution']['timing'].update(postStopThroughRequestCloseNanoseconds=100000))
    def test_rate_wrong(self):self.bad(lambda r,t:r[1]['execution']['timing'].update(promptTokensPerFirstTokenSecond=1.0))
    def test_rate_nonfinite(self):self.bad(lambda r,t:r[1]['execution']['timing'].update(promptTokensPerFirstTokenSecond=float('inf')))
    def test_negative_postclose(self):self.bad(lambda r,t:r[1]['execution']['timing'].update(postStopThroughRequestCloseNanoseconds=-1))
    def test_primary_postclose_overflow(self):self.bad(lambda r,t:r[1]['execution']['timing'].update(postStopThroughRequestCloseNanoseconds=c.U64))
    def test_unknown_base_field(self):self.bad(lambda r,t:r[1].update(throughputQualified=True))
    def test_failed_retirement(self):self.bad(lambda r,t:r[1]['execution'].update(allRequestStateRetired=False))
    def test_failed_outer_model_release(self):self.bad(lambda r,t:r[1].update(modelReleased=False))
    def test_wrong_ready_history(self):self.bad(lambda r,t:r[0].update(recordedRequestFingerprint='f'*64))
    def test_prompt_changed_without_history(self):self.bad(lambda r,t:r[1]['execution']['request']['promptTokenIDs'].__setitem__(0,2))
    def test_changed_chunk_commit(self):self.bad(lambda r,t:r[1]['execution']['commits'][0].update(committedTokens=1024))
    def test_stale_65_admission(self):self.bad(lambda r,t:r[1]['execution']['request']['request'].update(promptCount=65,chunkSize=32))
    def test_rank_action_change_matches_sidecar_still_rejected(self):
        self.rows,self.trace=f.rank(0)
        def edit(r,t):
            r[1]['execution']['actions'][5]['action']='invented';t['events'][5]['phase']='invented'
        self.bad(edit,'rank0')
    def test_rank_counter_changed(self):
        self.rows,self.trace=f.rank(0)
        self.bad(lambda r,t:r[1]['execution']['actions'][5].update(pendingConsumedFrameSlots=1),'rank0')
    def test_rank_policy_relabel_coherent_agreement(self):
        self.rows,self.trace=f.rank(0)
        def edit(r,t):
            agreement=r[1]['agreement'];agreement['schedulingPolicy']='prompt_lookahead_one_v1'
            fp=c.sha(b'qwen-profiled-prefill-start-agreement-v1\n'+c.canonical(agreement))
            for row in r:row['agreementFingerprint']=fp
            r[1]['execution']['agreementFingerprint']=fp;r[1]['execution']['preparedAheadFrames']=15
        self.bad(edit,'rank0')
    def test_rank1_forbidden_timing(self):
        self.rows,self.trace=f.rank(1);self.bad(lambda r,t:r[1]['execution'].update(timing={}), 'rank1')
    def test_rank0_forbidden_selection(self):
        self.rows,self.trace=f.rank(0);self.bad(lambda r,t:r[1]['execution'].update(localSelection={}), 'rank0')
    def test_rank0_close_timestamp_before_action(self):
        self.rows,self.trace=f.rank(0)
        self.bad(lambda r,t:r[1]['execution']['timing'].update(postStopThroughRequestCloseNanoseconds=0),'rank0')
    def test_cross_cohort_pair(self):
        r0,t0=f.rank(0);r1,t1=f.rank(1,epoch='102132435465768798a9bacbdcedfe0f')
        with self.assertRaises(ValueError):a.check_pair([r0,r1],[t0,t1])
    def test_swapped_rank_pair(self):
        r0,t0=f.rank(0);r1,t1=f.rank(1)
        with self.assertRaises(ValueError):a.check_pair([r1,r0],[t1,t0])
    def test_signed_zero_parser(self):self.assertEqual(str(c.parse(b'{"zero":-0}')['zero']),'-0.0')
    def test_duplicate_json_key(self):
        with self.assertRaises(ValueError):c.parse(b'{"clock":1,"clock":2}')
    def test_nested_duplicate_json_key(self):
        with self.assertRaises(ValueError):c.parse(b'{"identity":{"role":"solo","role":"rank0"}}')
    def test_json_nonfinite(self):
        for raw in [b'{"x":NaN}',b'{"x":Infinity}',b'{"x":1e309}']:
            with self.subTest(raw=raw),self.assertRaises(ValueError):c.parse(raw)
    def test_json_depth(self):
        with self.assertRaises(ValueError):c.parse(b'['*17+b'0'+b']'*17)
    def test_json_extra_row(self):
        with self.assertRaises(ValueError):c.stdout_rows(b'{}\n{}\n{}\n')
    def test_json_blank_row(self):
        with self.assertRaises(ValueError):c.stdout_rows(b'{}\n\n{}\n')
    def test_stdoutput_bound(self):
        with patch.object(c,'MAX_STDOUT',3),self.assertRaises(ValueError):c.stdout_rows(b'{}\n{}\n')
    def test_files_pin_and_parse(self):
        with tempfile.TemporaryDirectory() as tmp:
            stdout=Path(tmp)/'stdout.jsonl';trace=Path(tmp)/'phase.json'
            stdout.write_bytes(b'\n'.join(c.canonical(x) for x in self.rows)+b'\n');trace.write_bytes(c.canonical(self.trace))
            result=a.validate_solo(stdout,trace)
            self.assertTrue(result['frozenInputsUnchanged']);self.assertEqual(len(result['inputs']),2)
    def test_trace_file_bound(self):
        with tempfile.TemporaryDirectory() as tmp:
            stdout=Path(tmp)/'stdout.jsonl';trace=Path(tmp)/'phase.json'
            stdout.write_bytes(b'\n'.join(c.canonical(x) for x in self.rows));trace.write_bytes(b' '* (c.MAX_TRACE+1))
            with self.assertRaises(ValueError):a.validate_solo(stdout,trace)
    def test_duplicate_input_path(self):
        with self.assertRaises(ValueError):a.validate_solo('same','same')
    def test_frozen_dependency_mismatch(self):
        key=next(iter(c.PINNED))
        with patch.dict(c.PINNED,{key:'0'*64}),self.assertRaises(ValueError):c.verify_pins()
    def test_separate_numeric_scope_is_intentional(self):
        self.rows[1]['execution']['finalState']={'fabricated':'numerical oracle must reject'}
        self.assertFalse(a.check_records(self.rows,self.trace,'solo')['baseOutputFullyValidated'])


if __name__=='__main__':unittest.main(verbosity=2)
