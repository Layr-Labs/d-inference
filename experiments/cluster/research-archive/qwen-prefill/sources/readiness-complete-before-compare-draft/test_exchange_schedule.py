"""Pure finite schedule model. This does not emulate native streams or socket teardown."""
import copy
from pathlib import Path
import unittest

HERE = Path(__file__).parent
NEW = (('send','receive','compare'), ('receive','send','compare'))
OLD = (('send','receive','compare'), ('receive','compare','send'))


def schedules(order, digests):
    terminal = []
    def visit(state):
        moved = False
        for rank in (0,1):
            if state['done'][rank] or state['next'][rank] == 3: continue
            op = order[rank][state['next'][rank]]
            if op == 'receive' and state['mail'][rank] is None: continue
            moved = True; new = copy.deepcopy(state); new['next'][rank] += 1
            new['trace'].append((rank,op))
            if op == 'send': new['mail'][1-rank] = digests[rank]
            if op == 'receive': new['received'][rank] = new['mail'][rank]
            if op == 'compare':
                new['result'][rank] = new['received'][rank] == digests[rank]
                if not new['result'][rank]: new['done'][rank] = True
            visit(new)
        if not moved: terminal.append(state)
    visit(dict(next=[0,0], done=[False,False], mail=[None,None], received=[None,None],
               result=[None,None], trace=[]))
    return terminal


class ScheduleTests(unittest.TestCase):
    def test_native_source_has_only_cpu_return_and_post_exchange_comparison(self):
        source = (HERE/'QwenLongPrefillReadinessExchange.swift').read_text()
        receive = source[source.index('        func receive()'):source.index('        // Both ranks')]
        self.assertIn('throws -> [Int32]', receive); self.assertIn('return actual', receive)
        self.assertNotIn('guard actual == values', receive)
        self.assertEqual(source.count('guard actual == values'), 1)
        self.assertIn('if collective.rank == 0 { try send(); actual = try receive() }', source)
        self.assertIn('else { actual = try receive(); try send() }\n        try checked()\n        guard actual == values', source)
        self.assertIn('shape: [64], dtype: .int32', source)
        self.assertEqual(source.count('maximumBytes: 256'), 2)

    def test_all_admissible_matching_schedules_complete_both_peers(self):
        values = tuple(map(ord, 'a'*64)); traces = schedules(NEW, (values, values))
        self.assertGreater(len(traces), 1)
        for result in traces:
            self.assertEqual(result['result'], [True,True])
            self.assertEqual(len(result['trace']), 6)

    def test_all_admissible_mismatch_schedules_publish_and_reject_both(self):
        traces = schedules(NEW, (tuple(map(ord,'a'*64)), tuple(map(ord,'b'*64))))
        self.assertGreater(len(traces), 1)
        for result in traces:
            self.assertEqual(result['result'], [False,False])
            for rank in (0,1):
                self.assertLess(result['trace'].index((rank,'send')), result['trace'].index((rank,'compare')))

    def test_old_mismatch_order_strands_rank0_without_rank1_send(self):
        traces = schedules(OLD, (tuple(map(ord,'a'*64)), tuple(map(ord,'b'*64))))
        for result in traces:
            self.assertEqual(result['result'], [None,False])
            self.assertNotIn((1,'send'), result['trace'])


if __name__ == '__main__': unittest.main()
