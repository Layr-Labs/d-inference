"""CPU controls for retained evidence interpretation; no model/physical claims."""
import copy
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import compare_results_overlap as subject


def fixture(policy='oneChunkLookahead', mode='stage0', prompt=128):
    producer = policy == 'oneChunkLookahead' and mode == 'stage0'
    job = dict(promptCount=prompt, chunkSize=64, outputCount=16, mode=mode, prefillPolicy=policy)
    prefill_count = prompt // 64
    frames = []
    for sequence in range(prefill_count+15):
        prefill = sequence < prefill_count
        offset = sequence * 64 if prefill else prompt + sequence - prefill_count
        count = 64 if prefill else 1
        a = 110 if sequence == 0 else (150 if producer and prefill else 210) + (sequence-1)*60
        b = 200 if sequence == 0 else 260 + (sequence-1)*60
        phases = [dict(name=name, timestampNanoseconds=a+10+i, tokenCount=count,
                       committedTokens=offset+(count if i == 7 else 0))
                  for i, name in enumerate(subject.PHASES)]
        frames.append(dict(sequence=sequence, phase='prefill' if prefill else 'decode', offset=offset,
                           tokenCount=count, startedNanoseconds=a, completedNanoseconds=b, ownerPhases=phases))
    agreements = [f['completedNanoseconds']-1 for f in frames[prefill_count-1:]]
    sample = dict(startedNanoseconds=100, completedNanoseconds=frames[-1]['completedNanoseconds']+1,
                  timingsAreSameProcess=True, clockAcrossHostsCompared=False, evidenceOutsideTimedPath=True,
                  mtpEnabled=False, durationIncludesResourceChecksAndSerialTransport=policy == 'serial',
                  tokenAgreementNanoseconds=agreements, frames=frames)
    if mode != 'full':
        sample['prefillSummary'] = dict(policy=policy, rank=0 if mode == 'stage0' else 1,
            preparedAheadFrames=prefill_count-1 if producer else 0, maximumPreparedBoundaries=1 if producer else 0,
            pendingConsumedAtCompletion=0, decodePrefetchCount=0)
    if mode != 'stage0':
        sample['firstLogitsNanoseconds'] = agreements[0]-1
    return dict(job=job, loadStartedNanoseconds=1, loadCompletedNanoseconds=2,
                probeCompletedNanoseconds=3, samples=[sample])


def resource_pair(rank=0):
    base = dict(policy='registered_gemma4_resident_benchmark_resources_v1', planSHA256='plan', requestSHA256='request',
        selectedTensorCount=2, completedTensorCount=2, selectedAllocationBounds=[16,32],
        persistentCastLogicalBytes=16, stateLogicalBytes=16,
        actualAllocatorBoundsUsed=True, operationalResourceChecksApplied=True, reclaimableUsedForAdmission=False,
        minimumActualFreeBytes=6*1024**3, observationCount=1,
        namedArrays=[dict(name='residual',bytes=16)], namedAllocationBounds=[16],
        namedNativeReserveBytes=16, hostEvidenceReserveBytes=100)
    added = copy.deepcopy(base); logical = 64*2816*4 if rank == 0 else 0
    native = logical+64 if logical else 0
    if logical:
        added['namedArrays'].append(dict(name='lookaheadPreparedBoundary',bytes=logical))
        added['namedAllocationBounds'].append(native)
    added['prefillAllowance'] = dict(rank=rank, extraNativeBytes=native, extraHostBytes=logical+65_536)
    added['namedNativeReserveBytes'] += native; added['hostEvidenceReserveBytes'] += logical+65_536
    job = dict(mode='stage0' if rank == 0 else 'stage1', promptCount=128, chunkSize=64)
    return dict(resources=base), dict(resources=added, job=job)


class OverlapClocks(unittest.TestCase):
    def test_valid_producer_receiver_and_serial(self):
        for policy, mode in [('oneChunkLookahead','stage0'), ('oneChunkLookahead','stage1'),
                             ('serial','stage0'), ('serial','full')]:
            with self.subTest(policy=policy, mode=mode):
                self.assertEqual(subject.request_clocks(fixture(policy,mode)),17)
        self.assertEqual(subject.request_clocks(fixture(prompt=256)),19)

    def test_serial_overlap_refused(self):
        value = fixture('serial'); value['samples'][0]['frames'][1]['startedNanoseconds'] = 150
        with self.assertRaises(ValueError): subject.request_clocks(value)

    def test_local_owner_overlap_refused(self):
        value = fixture(); frame = value['samples'][0]['frames'][1]
        frame['startedNanoseconds'] = 120
        for i,p in enumerate(frame['ownerPhases']): p['timestampNanoseconds'] = 120+i
        with self.assertRaises(ValueError): subject.request_clocks(value)

    def test_next_commit_after_previous_completion_refused(self):
        value = fixture(); value['samples'][0]['frames'][1]['ownerPhases'][-1]['timestampNanoseconds'] = 201
        with self.assertRaises(ValueError): subject.request_clocks(value)

    def test_second_prepared_chunk_before_old_ack_refused(self):
        value = fixture(prompt=256); frame = value['samples'][0]['frames'][2]
        frame['startedNanoseconds'] = 190
        for i,p in enumerate(frame['ownerPhases']): p['timestampNanoseconds'] = 200+i
        with self.assertRaises(ValueError): subject.request_clocks(value)

    def test_decode_overlap_refused(self):
        value = fixture(); value['samples'][0]['frames'][2]['startedNanoseconds'] = 250
        with self.assertRaises(ValueError): subject.request_clocks(value)

    def test_ack_frontier_confusion_refused(self):
        value = fixture(); value['samples'][0]['frames'][0]['ownerPhases'][-1]['committedTokens'] = 128
        with self.assertRaises(ValueError): subject.request_clocks(value)

    def test_nonempty_pending_or_decode_prefetch_refused(self):
        for field in ('pendingConsumedAtCompletion','decodePrefetchCount','maximumPreparedBoundaries'):
            value = fixture(); value['samples'][0]['prefillSummary'][field] += 1
            with self.subTest(field=field), self.assertRaises(ValueError): subject.request_clocks(value)

    def test_allowance_is_additional_for_both_ranks(self):
        for rank in (0,1):
            serial, overlap = resource_pair(rank)
            self.assertEqual(subject.budget_delta(serial,overlap)['rank'],rank)

    def test_dropped_base_term_or_host_charge_refused(self):
        for mutation in ('base','host','native'):
            serial, overlap = resource_pair()
            if mutation == 'base': overlap['resources']['namedArrays'][0]['name'] = 'replacement'
            elif mutation == 'host': overlap['resources']['hostEvidenceReserveBytes'] -= 1
            else: overlap['resources']['namedNativeReserveBytes'] -= 1
            with self.subTest(mutation=mutation), self.assertRaises(ValueError):
                subject.budget_delta(serial,overlap)


if __name__ == '__main__':
    unittest.main()
