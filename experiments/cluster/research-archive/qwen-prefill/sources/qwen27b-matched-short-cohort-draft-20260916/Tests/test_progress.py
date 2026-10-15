"""Fabricated values and owned local Python children; no model or performance evidence."""
import copy
import hashlib
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest

BASE = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(BASE / 'run-template'))
from binding_common import canonical
from solo_contract import admitted, expected_identity, report
from solo_progress import loaded, retired, reconcile
from run_solo import serve
from worker_contract import WorkerSpec
import test_legacy_contract as legacy


def fixture():
    old = legacy.ContractChecks(); old.setUp()
    job = dict(old.job, schema='private_resident_solo_generation_job_v2', measured_count=1)
    identity = expected_identity(job, [17]*8192, [19]*128)
    first, final = copy.deepcopy(old.first), copy.deepcopy(old.final)
    first.update(measuredCount=1, requestIDs=first['requestIDs'][:2],
                 requestFingerprints=first['requestFingerprints'][:2])
    final.update(measuredCount=1, freshRequestsAdmitted=2,
                 requests=final['requests'][:2], memory=final['memory'][:5])
    model = dict(kind='qwen_resident_solo_model_loaded', schemaVersion=1,
        verifiedFullModelLoads=1, freshRequestStateCreated=False, modelReleased=False,
        cohortCompleted=False, warmupCount=1, measuredCount=1,
        firstRequestID=first['requestIDs'][0], firstRequestFingerprint=first['requestFingerprints'][0],
        expectedTokenFileSHA256=job['expected_sha256'], source=final['source'],
        sourceLoad=final['sourceLoad'], publishedNanoseconds=500_000_000)
    rows = [dict(kind='qwen_resident_solo_request_retired', schemaVersion=1,
        modelReleased=False, cohortCompleted=False, warmupCount=1, measuredCount=1,
        expectedTokenFileSHA256=job['expected_sha256'], request=row,
        kernelEligibility=final['kernelEligibility'],
        publishedNanoseconds=row['execution']['timing']['retiredNanoseconds']+1)
        for row in final['requests']]
    return job, identity, first, model, rows, final


class ProgressChecks(unittest.TestCase):
    def test_complete_short_and_default_legacy_contracts(self):
        job, identity, first, model, rows, final = fixture()
        first = admitted(canonical(first), identity)
        value = loaded(canonical(model), identity, first)
        previous = value['publishedNanoseconds']
        for index, row in enumerate(rows):
            checked = retired(canonical(row), identity, first, index, previous)
            previous = checked['publishedNanoseconds']
        last = report(canonical(final), identity, first, 1, Path('/invented/native'))
        reconcile(last, value, rows)
        self.assertEqual(len(last['requests']), 2)
        old = legacy.ContractChecks(); old.setUp(); self.assertEqual(len(old.check()['requests']), 4)

    def test_false_loaded_or_wrong_source_refused(self):
        _, identity, first, model, _, _ = fixture()
        for key, value in [('verifiedFullModelLoads', 0), ('cohortCompleted', True),
                           ('firstRequestFingerprint', 'f'*64), ('measuredCount', 3)]:
            bad = copy.deepcopy(model); bad[key] = value
            with self.subTest(key=key), self.assertRaises(ValueError): loaded(canonical(bad), identity, first)
        bad = copy.deepcopy(model); bad['sourceLoad']['tensorCount'] = 927
        with self.assertRaises(ValueError): loaded(canonical(bad), identity, first)

    def test_missing_duplicate_early_or_unretired_request_refused(self):
        _, identity, first, model, rows, _ = fixture()
        with self.assertRaises(ValueError): retired(canonical(rows[1]), identity, first, 0, model['publishedNanoseconds'])
        with self.assertRaises(ValueError): retired(canonical(rows[0]), identity, first, 1, rows[0]['publishedNanoseconds'])
        for mutation in ('early', 'unretired', 'bad_token', 'wrong_warmup'):
            bad = copy.deepcopy(rows[0])
            if mutation == 'early': bad['publishedNanoseconds'] = 1
            if mutation == 'unretired': bad['request']['execution']['allRequestStateRetired'] = False
            if mutation == 'bad_token': bad['request']['execution']['selectedTokenIDs'][0] = 20
            if mutation == 'wrong_warmup': bad['kernelEligibility']['warmupDispatch']['nativePrefillCalls'] = 384
            with self.subTest(mutation=mutation), self.assertRaises(ValueError):
                retired(canonical(bad), identity, first, 0, model['publishedNanoseconds'])

    def test_final_must_match_all_retained_progress(self):
        _, _, _, model, rows, final = fixture()
        for altered in ('missing', 'changed'):
            bad = copy.deepcopy(final)
            if altered == 'missing': bad['requests'].pop()
            else: bad['requests'][1]['execution']['timing']['prefillSeconds'] = 2
            with self.subTest(altered=altered), self.assertRaises(ValueError): reconcile(bad, model, rows)

    def child(self, stop_after=None):
        job, _, first, model, rows, final = fixture()
        class Pins:
            def recheck(self): pass
        with tempfile.TemporaryDirectory(prefix='solo-progress-cpu-') as temporary:
            base = Path(temporary); run = base/'run'; run.mkdir()
            data = base/'data.json'
            data.write_text(json.dumps([first, model, *rows, final]))
            child = base/'child.py'
            child.write_text('''import json,os,sys
rows=json.load(open(sys.argv[1]))
rows[-1]['runtime']['processID']=os.getpid()
for row in rows[:int(sys.argv[2])]:
 print(json.dumps(row,separators=(',',':')),flush=True)
''')
            count = 5 if stop_after is None else stop_after
            spec = WorkerSpec((sys.executable, '-B', str(child), str(data), str(count)),
                              {'PATH': '/usr/bin:/bin'}, 'solo', None)
            code = serve(job, spec, [17]*8192, [19]*128, run, lambda _: None, Pins(), timeout=10)
            terminal = json.loads((run/'terminal.json').read_bytes())
            raw = (run/'native/worker-0.stdout').read_bytes()
            self.assertEqual(terminal['nativeExitCodes'], [0])
            self.assertTrue(terminal['nativeLeaderReaped'])
            self.assertTrue(terminal['ownedGroupFenceComplete'])
            return code, terminal, raw

    def test_actual_child_complete_progress_then_final(self):
        code, terminal, raw = self.child()
        self.assertEqual(code, 0)
        self.assertTrue(terminal['cohortTimingEligible'])
        self.assertEqual(terminal['recordsAccepted'], 5)
        self.assertEqual(terminal['completedRequestRecords'], 2)
        self.assertEqual(len(raw.splitlines()), 5)

    def test_actual_child_failure_preserves_completed_warmup_without_aggregation(self):
        code, terminal, raw = self.child(stop_after=3)
        self.assertEqual(code, 1)
        self.assertFalse(terminal['cohortTimingEligible'])
        self.assertEqual(terminal['lastAcceptedPhase'], 'request-0-retired')
        self.assertEqual(terminal['completedRequestRecords'], 1)
        self.assertNotIn('requests', terminal)
        self.assertEqual(len(raw.splitlines()), 3)


if __name__ == '__main__':
    unittest.main()
