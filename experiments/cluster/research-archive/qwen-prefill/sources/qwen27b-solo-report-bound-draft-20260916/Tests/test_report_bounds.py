"""CPU report/pipe checks; fabricated cohorts never qualify actual performance."""
import copy
import json
import os
from pathlib import Path
import shutil
import sys
import tempfile
import unittest

BASE = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(BASE/'run-template'))
from binding_common import canonical
from solo_contract import admitted, expected_identity, report
from solo_progress import loaded, retired, reconcile
from run_solo import serve
from worker_contract import MAX_LINE, MAX_OUTPUT, WorkerSpec


class ReportBoundChecks(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.fixture = json.loads((BASE/'Tests/generated/cases.json').read_bytes())

    def validate(self, case, raw=None):
        expected = expected_identity(case['job'], self.fixture['tokens'], self.fixture['expected'])
        first = admitted(canonical(case['first']), expected)
        model = loaded(canonical(case['model']), expected, first)
        previous = model['publishedNanoseconds']
        for i, row in enumerate(case['rows']):
            value = retired(canonical(row), expected, first, i, previous)
            previous = value['publishedNanoseconds']
        final = report(canonical(case['final']) if raw is None else raw, expected, first, 1,
                       Path(case['job']['deployment']))
        reconcile(final, model, case['rows'])
        return final

    def test_all_counts_preserve_actual_1847_tensor_ledger(self):
        for case in self.fixture['cases']:
            with self.subTest(measured=case['measured']):
                raw = canonical(case['final'])
                self.assertGreater(len(raw), 128*1024)
                self.assertLess(len(raw), 512*1024)
                final = self.validate(case)
                for key in ('sourceNames', 'sourceByteCounts', 'allocationBounds'):
                    self.assertEqual(len(final['resources']['budget'][key]), 1847)
                    self.assertEqual(final['resources']['budget'][key], case['final']['resources']['budget'][key])

    def test_final_exact_cap_and_one_byte_over(self):
        case = self.fixture['cases'][2]
        raw = canonical(case['final'])
        self.validate(case, raw + b' ' * (512*1024-len(raw)))
        with self.assertRaisesRegex(ValueError, 'Solo report bound'):
            self.validate(case, raw + b' ' * (512*1024+1-len(raw)))

    def test_progress_caps_remain_128k(self):
        case = self.fixture['cases'][0]
        expected = expected_identity(case['job'], self.fixture['tokens'], self.fixture['expected'])
        callbacks = [(case['first'], lambda raw: admitted(raw, expected)),
            (case['model'], lambda raw: loaded(raw, expected, case['first'])),
            (case['rows'][0], lambda raw: retired(raw, expected, case['first'], 0, case['model']['publishedNanoseconds']))]
        for value, check in callbacks:
            raw = canonical(value)
            check(raw + b' ' * (128*1024-len(raw)))
            with self.assertRaises(ValueError): check(raw + b' ' * (128*1024+1-len(raw)))

    def test_global_pipe_caps_unchanged_and_cover_maximum_cohort(self):
        self.assertEqual((MAX_LINE, MAX_OUTPUT), (32*1024*1024, 160*1024*1024))
        self.assertLess(512*1024+1, MAX_LINE)
        self.assertLess(6*128*1024+512*1024+7, MAX_OUTPUT)

    def child(self, missing_final=False):
        case = self.fixture['cases'][0]
        class Pins:
            def recheck(self): pass
        with tempfile.TemporaryDirectory(prefix='solo-large-report-cpu-') as tmp:
            root = Path(tmp); run = root/'run'; run.mkdir()
            values = [case['first'], case['model'], *case['rows'], case['final']]
            (root/'rows.json').write_bytes(canonical(values))
            (root/'child.py').write_text('''import json,os,sys
rows=json.load(open(sys.argv[1]))
rows[-1]['runtime']['processID']=os.getpid()
for row in rows[:int(sys.argv[2])]:
 print(json.dumps(row,separators=(',',':')),flush=True)
''')
            spec = WorkerSpec((sys.executable, '-B', str(root/'child.py'), str(root/'rows.json'),
                               '4' if missing_final else '5'), {'PATH':'/usr/bin:/bin'}, 'solo', None)
            code = serve(case['job'], spec, self.fixture['tokens'], self.fixture['expected'], run,
                         lambda _: None, Pins(), timeout=10)
            terminal = json.loads((run/'terminal.json').read_bytes())
            evidence = os.environ.get('SOLO_REPORT_CHILD_EVIDENCE_DIR')
            if evidence:
                destination = Path(evidence)/('missing-final' if missing_final else 'complete')
                shutil.copytree(run, destination)
            self.assertEqual(terminal['nativeExitCodes'], [0])
            self.assertTrue(terminal['nativeLeaderReaped'])
            self.assertTrue(terminal['ownedGroupFenceComplete'])
            # Failed EOF can race an already-exited unreaped group (EPERM is
            # retained by the unchanged owner). It must remain a failed cohort.
            if not missing_final: self.assertEqual(terminal['cleanupErrors'], [])
            return code, terminal, (run/'native/worker-0.stdout').read_bytes()

    def test_actual_child_large_final_is_required_then_retired(self):
        code, terminal, raw = self.child()
        self.assertEqual(code, 0)
        self.assertTrue(terminal['cohortTimingEligible'])
        self.assertEqual(terminal['recordsAccepted'], 5)
        self.assertGreater(len(raw.splitlines()[-1]), 128*1024)

    def test_actual_child_missing_final_keeps_completed_samples_unqualified(self):
        code, terminal, raw = self.child(missing_final=True)
        self.assertEqual(code, 1)
        self.assertFalse(terminal['cohortTimingEligible'])
        self.assertEqual(terminal['completedRequestRecords'], 2)
        self.assertNotIn('requests', terminal)
        self.assertEqual(len(raw.splitlines()), 4)


def validate_swift(directory):
    """Run after the actual Foundation encoder so its bytes cross the real parser."""
    ReportBoundChecks.setUpClass()
    check = ReportBoundChecks()
    for case in check.fixture['cases']:
        raw = (Path(directory)/('report-'+str(case['measured'])+'.jsonl')).read_bytes()
        assert raw.endswith(b'\n') and b'\n' not in raw[:-1]
        check.validate(case, raw[:-1])
    print('All 3 actual Swift-encoded reports passed the production parser and full-ledger checks.')


if __name__ == '__main__':
    if len(sys.argv) == 3 and sys.argv[1] == '--swift-output': validate_swift(sys.argv[2])
    else: unittest.main()
