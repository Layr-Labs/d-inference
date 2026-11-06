"""CPU mutations of actual retry1 evidence, plus a derived serialized fixture."""
import copy
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('lookahead_audit', ROOT / 'qwen_layer_stage_lookahead_audit.py')
audit = importlib.util.module_from_spec(spec); spec.loader.exec_module(audit)
RANK = audit.rank_helper()
EPOCH = '5703b01082534e7b875c9919b1320b27'
OLD_PATH = ROOT / 'runs/qwen-layer-stage-real9b-20260913/native/stdout.txt'
SERIAL_RUN = ROOT / 'runs/qwen-layer-stage-ranks-20260914'
SERIAL_SHAS = ['06197786dbb58d801b6d23d9ba63408517dfa95ac2387d311e6401b1d33e4764',
    '7ddbb462b0ee84904a6d66786254a0c4188809ac03cc28e2a95b740d32dd0089']
ACTUAL_RUN = ROOT / 'runs/qwen-layer-stage-lookahead-retry1-20260914'
ACTUAL_SHAS = ['da7d83f2d4579aa2b425f40749f07b759d05c8ccce975c89987fe1a247b41ff7',
    'b921fd64ff1cfc87bce10192de7ce6c313be1b6fe05435b3330a21c3b482e989']


def synthetic_rows(old_rows):
    new_request, simple, recorded = RANK.fresh_request(old_rows[0]['baseline']['request'], EPOCH)
    result = []
    for rank in range(2):
        rows, observed = RANK.read_rows(SERIAL_RUN / f'rank-{rank}/stdout.jsonl')
        assert observed == SERIAL_SHAS[rank]
        ready, report = rows
        ready.update(kind='qwen_layer_stage_lookahead_ready', epoch=EPOCH, flow=audit.FLOW, envelopeVersion=2)
        report.update(kind='qwen_layer_stage_lookahead_report', epoch=EPOCH, flow=audit.FLOW, envelopeVersion=2,
            request=copy.deepcopy(new_request))
        completions = report.pop('frames')
        for index, completion in enumerate(completions):
            completion['capture']['identity']['requestFingerprint'] = simple
            wire = audit.wire_identity(old_rows[1]['stageLoads'][0], simple, new_request['steps'][index],
                completion['capture']['boundaryPayloadSHA256'])
            completion['headerSHA256'] = wire['envelopeSHA256']
        actions = audit.expected_actions(rank, new_request['steps'], [x['headerSHA256'] for x in completions])
        report['execution'] = dict(audit.expected_execution_summary(rank,
            RANK.session_identity(report['sourceLoad'], rank, simple), recorded, actions), completions=completions, actions=actions)
        result.append([ready, report])
    return result


def set_path(path, value):
    def mutate(rows):
        target = rows
        for key in path[:-1]: target = target[key]
        target[path[-1]] = value
    return mutate


def wrong_both_v1_headers(rows):
    for rank in range(2):
        report = rows[rank][1]; _, simple, _ = RANK.fresh_request(LookaheadTests.old[0]['baseline']['request'], EPOCH)
        for index, completion in enumerate(report['execution']['completions']):
            before = completion['headerSHA256']
            value = audit.wire_identity(LookaheadTests.old[1]['stageLoads'][0], simple, report['request']['steps'][index],
                completion['capture']['boundaryPayloadSHA256'])['v1HeaderSHA256']
            completion['headerSHA256'] = value
            for action in report['execution']['actions']:
                if action.get('headerSHA256') == before: action['headerSHA256'] = value


def coherent_both_tokens(rows):
    for rank in range(2):
        report = rows[rank][1]; request = report['request']
        request['promptTokenIDs'][0] += 1; request['steps'][0]['tokenIDs'][0] += 1
        simple = report['execution']['identity']['requestFingerprint']
        request['fingerprint'] = audit.sha(('qwen-layer-stage-recorded-request-v1\n' + simple + '\nvocabulary=248320\nprompt='
            + ','.join(map(str, request['promptTokenIDs'])) + '\nteacher=' + ','.join(map(str, request['teacherTokenIDs']))).encode())
        report['execution']['recordedRequestFingerprint'] = request['fingerprint']
        completion = report['execution']['completions'][0]; before = completion['headerSHA256']
        completion['headerSHA256'] = audit.wire_identity(LookaheadTests.old[1]['stageLoads'][0], simple,
            request['steps'][0], completion['capture']['boundaryPayloadSHA256'])['envelopeSHA256']
        for action in report['execution']['actions']:
            if action.get('headerSHA256') == before: action['headerSHA256'] = completion['headerSHA256']


def coherent_state_digest(rows):
    capture = rows[0][1]['execution']['completions'][0]['capture']
    capture['stateEntries'][0]['sha256'] = 'a' * 64
    capture['stageStateSHA256'] = RANK.state_hash(capture['stateEntries'], capture['committedTokens'])


def delayed_first_preparation(rows):
    # A coherent serial first transition still computes the same model inputs,
    # but must not qualify as the specific admitted prompt-lookahead schedule.
    execution = rows[0][1]['execution']; actions = execution['actions']
    ahead = actions[9:11]
    assert [x['action'] for x in ahead] == ['beginPreparation', 'preparationCompleted']
    assert [x['action'] for x in actions[11:14]] == ['send.beginConsumedDrain', 'send.consumedACKAccepted', 'frameCompletion']
    for action in actions[11:14]:
        action['producedFrames'] = 1; action['nativeCommittedTokens'] = 32; action['explicitNativeBoundarySlots'] = 0
    for action in ahead:
        action['completedFrames'] = 1; action['pendingConsumedFrameSlots'] = 0
    actions[9:14] = actions[11:14] + ahead
    for index, action in enumerate(actions): action['ordinal'] = index
    execution['promptLookaheadCount'] = 1


def omit_release_with_renumbering(rows):
    actions = rows[1][1]['execution']['actions']
    index = next(i for i, a in enumerate(actions) if a['action'] == 'receive.consumedBoundaryReleased')
    actions.pop(index)
    for index, action in enumerate(actions): action['ordinal'] = index


MUTATIONS = {
    'both_v1_headers_and_trace_hashes': wrong_both_v1_headers,
    'both_token_history_and_recomputed_hashes': coherent_both_tokens,
    'state_digest_and_recomputed_fingerprint': coherent_state_digest,
    'coherent_serial_first_preparation': delayed_first_preparation,
    'removed_release_and_renumbered_trace': omit_release_with_renumbering,
    'ready_flow': set_path([0, 0, 'flow'], 'strict_v1'),
    'envelope_version': set_path([1, 1, 'envelopeVersion'], 1),
    'fresh_epoch': set_path([1, 1, 'epoch'], 'f' * 32),
    'nested_execution_twice': set_path([0, 1, 'execution', 'execution'], {}),
    'old_completion_capture_used_at_new_frontier': set_path([0, 1, 'execution', 'completions', 0, 'capture', 'committedTokens'], 64),
    'source_retained_count': set_path([0, 1, 'sourceLoad', 'storageCommitment', 'sourceTensorCount'], 1291),
    'wrong_lookahead_count': set_path([0, 1, 'execution', 'promptLookaheadCount'], 1),
    'wrong_maximum_gap': set_path([0, 1, 'execution', 'maximumProducedMinusCompleted'], 1),
    'sender_fields_on_receiver': set_path([1, 1, 'execution', 'producedFrames'], 6),
    'action_boolean_counter': set_path([0, 1, 'execution', 'actions', 0, 'producedFrames'], False),
    'action_wrong_native_frontier': set_path([0, 1, 'execution', 'actions', 11, 'nativeCommittedTokens'], 32),
    'action_wrong_slot_count': set_path([0, 1, 'execution', 'actions', 11, 'explicitNativeBoundarySlots'], 0),
    'action_wrong_pending_ticket': set_path([0, 1, 'execution', 'actions', 11, 'headerSHA256'], 'f' * 64),
    'received_claims_consumed': set_path([1, 1, 'execution', 'actions', 7, 'action'], 'receive.consumedACKSendCompleted'),
    'action_invents_optional_header': set_path([1, 1, 'execution', 'actions', 0, 'headerSHA256'], 'f' * 64),
    'release_counter': set_path([1, 1, 'execution', 'releasedOriginalArrayHandles'], 5),
    'retirement_flag': set_path([0, 1, 'execution', 'allRequestStateRetired'], False),
    'logit_value_without_matching_digest': set_path([1, 1, 'execution', 'completions', 2, 'capture', 'logits', 'values', 0], 123),
}


class LookaheadTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.old, observed = RANK.read_rows(OLD_PATH); assert observed == RANK.BASELINE_STDOUT_SHA
        cls.expected = json.loads((ROOT / 'qwen-layer-stage-real9b-expected-20260913.json').read_text())
        cls.rows = []
        for rank in range(2):
            rows, observed = RANK.read_rows(ACTUAL_RUN / f'rank-{rank}/stdout.jsonl')
            assert observed == ACTUAL_SHAS[rank]
            cls.rows.append(rows)

    def test_actual_positive(self):
        summary = audit.validate_reports(self.rows, self.old, EPOCH, self.expected)
        self.assertEqual((summary['actionCounts'], summary['combinedStateEntriesChecked'], summary['nativeLogitValuesPerSide']),
            ([73, 85], 432, 993280))
        sender_actions = self.rows[0][1]['execution']['actions']
        self.assertEqual(sender_actions[9]['action'], 'beginPreparation')
        self.assertEqual(sender_actions[9]['frameSequence'], 1)
        self.assertEqual(sender_actions[11]['action'], 'send.beginConsumedDrain')
        self.assertEqual((sender_actions[11]['frameSequence'], sender_actions[11]['nativeCommittedTokens']), (0, 64))

    def test_synthetic_positive_from_serialized_native_captures(self):
        summary = audit.validate_reports(synthetic_rows(self.old), self.old, EPOCH, self.expected)
        self.assertEqual(summary['actionCounts'], [73, 85])

    def test_phase_identities_are_distinct_and_v2(self):
        request, simple, _ = RANK.fresh_request(self.old[0]['baseline']['request'], EPOCH)
        wire = audit.wire_identity(self.old[1]['stageLoads'][0], simple, request['steps'][0], 'a' * 64)
        self.assertEqual(len(set(wire['expectedACKLogicalBytesSHA256'].values())), 3)
        self.assertNotEqual(wire['v1HeaderSHA256'], wire['envelopeSHA256'])

    def test_one_ready_record_is_not_success(self):
        with tempfile.TemporaryDirectory(prefix='lookahead-incomplete-') as directory:
            paths = [Path(directory) / f'rank-{rank}.jsonl' for rank in range(2)]
            for path, rows in zip(paths, self.rows): path.write_bytes(RANK.canonical(rows[0]) + b'\n')
            with self.assertRaisesRegex(ValueError, 'exactly ready/checkpoint then terminal'):
                audit.validate(paths, OLD_PATH, EPOCH, self.expected)

    def test_actual_resource_aborted_run_is_not_success(self):
        run = ROOT / 'runs/qwen-layer-stage-lookahead-20260914'
        if not run.exists(): self.skipTest('First resource-aborted archive unavailable')
        paths = [run / f'rank-{rank}/stdout.jsonl' for rank in range(2)]
        for path in paths:
            with self.assertRaisesRegex(ValueError, 'exactly ready/checkpoint then terminal'): RANK.read_rows(path)


def negative(mutate):
    def test(self):
        rows = copy.deepcopy(self.rows); mutate(rows)
        with self.assertRaises(ValueError): audit.validate_reports(rows, self.old, EPOCH, self.expected)
    return test


for name, mutate in MUTATIONS.items(): setattr(LookaheadTests, 'test_reject_' + name, negative(mutate))


if __name__ == '__main__': unittest.main()
