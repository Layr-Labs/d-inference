"""Pure output-contract/source checks plus fake CPU children; never load MLX."""
import ast
import copy
import json
from pathlib import Path
import sys
import tempfile
import time
import unittest

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT / 'package'))
from binding_common import canonical
from target_contract import JOBS, validate_result
from target_processes import parse_processes
from target_supervision import serve
from worker_contract import WorkerSpec
from window_result import EXPECTED, GROUPS
from transaction_result import EXPECTED as TARGET


class WindowContractTests(unittest.TestCase):
    def test_exact_cases_and_types(self):
        self.assertEqual(len(GROUPS), 21)
        self.assertEqual(validate_result(canonical(EXPECTED), 'window'), EXPECTED)
        for key in EXPECTED:
            bad = copy.deepcopy(EXPECTED)
            if type(bad[key]) is bool: bad[key] = not bad[key]
            elif type(bad[key]) is int: bad[key] += 1
            elif type(bad[key]) is list: bad[key] = bad[key][:-1]
            else: bad[key] += '-wrong'
            with self.subTest(key=key), self.assertRaises(ValueError):
                validate_result(canonical(bad), 'window')
        for value in (dict(EXPECTED, maximumTokens=True), dict(EXPECTED, maximumTokens=32.0),
                      dict(EXPECTED, unexpected=True), dict(EXPECTED, passed=GROUPS[::-1])):
            with self.assertRaises(ValueError): validate_result(canonical(value), 'window')
        for raw in (b'x'*16385, b'{"fixture":1,"fixture":2}'):
            with self.assertRaises(ValueError): validate_result(raw, 'window')

    def test_cross_fixture_outputs_are_refused(self):
        self.assertEqual(validate_result(canonical(TARGET), 'target'), TARGET)
        for raw, fixture in [(canonical(TARGET), 'window'), (canonical(EXPECTED), 'target'),
                             (canonical(EXPECTED), 'session'), (canonical(EXPECTED), 'unknown')]:
            with self.assertRaises(ValueError): validate_result(raw, fixture)

    def test_source_entry_alarms_and_commands(self):
        source = ROOT/'package/native-contract/sources/libs/darkbloom-cluster-worker/Tests'
        for job in JOBS.values():
            code = (source/job['product']/'Main.swift').read_text()
            self.assertIn('alarm('+str(job['processAlarmSeconds'])+')', code)
            self.assertIn('["'+job['runArguments'][0]+'"]', code)
        for path in list(ROOT.glob('*.py')) + list((ROOT/'package').rglob('*.py')):
            ast.parse(path.read_text(), filename=str(path))

    def test_actual_cpu_child_contract_and_failure_cleanup(self):
        class Pins:
            def recheck(self): pass
        for fixture, output, status in [('window', EXPECTED, 0), ('target', TARGET, 0),
                                         ('window', dict(EXPECTED, passed=[]), 1)]:
            with self.subTest(fixture=fixture, status=status), tempfile.TemporaryDirectory() as folder:
                code = 'import sys; sys.stdout.buffer.write('+repr(canonical(output)+b'\n')+');sys.stdout.flush()'
                spec = WorkerSpec((sys.executable, '-c', code), {'PATH':'/usr/bin:/bin'}, 'solo', None)
                result = serve(spec, Path(folder), time.monotonic(), lambda _:None, Pins(), lambda:{}, fixture)
                receipt = json.loads((Path(folder)/'terminal.json').read_text())
                self.assertEqual(result, status)
                self.assertTrue(receipt['nativeLeaderReaped'] and receipt['ownedGroupsAbsent'])
                self.assertEqual(receipt['windowStateExecutionObserved'], fixture == 'window' and status == 0)
                self.assertEqual(receipt['modelTrunkExecutionObserved'], fixture != 'target' and status == 0)
                self.assertFalse(receipt['bilateralVerification'])

    def test_inventory_includes_all_three_native_products(self):
        raw = ''.join(str(i+40)+' 501 /tmp/'+x['product']+'\n' for i,x in enumerate(JOBS.values())).encode()
        self.assertEqual(len(parse_processes(raw)['prohibited']), 3)


if __name__ == '__main__': unittest.main()
