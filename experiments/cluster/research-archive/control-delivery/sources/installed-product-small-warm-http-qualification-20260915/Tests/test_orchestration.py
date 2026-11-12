"""Mock ownership/HTTP adapters; no subprocess, remote connection or native work."""
from contextlib import ExitStack, nullcontext, redirect_stdout
import io
import json
from pathlib import Path
import shutil
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch
from receipt_fixture import CLIENT, HARNESS, receipt
import run as harness


class OrchestrationChecks(unittest.TestCase):
    def scenario(self, warmup_status='completed', warmup_outputs=123, measured_count=8192):
        calls = []
        native = SimpleNamespace(stdin=io.BytesIO(), stdout=io.BytesIO(), returncode=None)

        def communicate(timeout):
            calls.append('supervisor-retired'); native.returncode = 0
            return b'{"state":"stopped"}\n', None

        native.communicate = communicate
        native.poll = lambda: native.returncode

        def popen(*args, **kwargs):
            calls.append('product-start'); return native

        def monitor(*args):
            return SimpleNamespace(first=SimpleNamespace(get=lambda timeout: {'admissible': True}),
                require=lambda: None, stop=lambda: {'exitCode': 0, 'errors': []})

        def alias(*args):
            return SimpleNamespace(ready=lambda: {'ready': True}, stop=lambda: {'restored': True})

        def token(path):
            path.write_text('fake-test-token'); return True

        def tokenizer(rendered, expected, token, output):
            count = len(json.loads(expected.read_bytes()))
            calls.append('tokenizer-' + str(count))
            return dict(tokenCount=count, everyTokenIDMatched=True)

        def client(command, **kwargs):
            output = Path(command[command.index('--output')+1]); output.mkdir()
            prompt = Path(command[command.index('--prompt-file')+1]).read_text()
            warm = output.name == 'warmup-client'
            calls.append('warmup-client' if warm else 'measured-client')
            value = receipt(prompt=prompt, count=512 if warm else measured_count,
                            outputs=warmup_outputs if warm else 128,
                            finish='stop' if warm else 'length',
                            content=not (warm and warmup_status == 'no_content'))
            if warm and warmup_status == 'failed':
                value['status'] = 'failed'
                value['error'] = dict(type='TimeoutError', code='absolute_timeout')
            (output/'receipt.json').write_text(json.dumps(value))
            return SimpleNamespace(returncode=0 if value['status'] == 'completed' else 1)

        with tempfile.TemporaryDirectory() as name, ExitStack() as scope:
            base = Path(name)
            shutil.copytree(HARNESS/'stage_checks', base/'stage_checks')
            replacements = dict(BASE=base, Monitor=monitor, AliasLease=alias,
                line_until=lambda *args: {'state': 'started', 'pid': 765}, fetch_token=token,
                discovery=lambda: dict(pid=765, host='192.0.2.250', port=18081),
                verify_tokenizer=tokenizer,
                postflight=lambda *args: dict(files={}, active=[], journalBytes=0))
            for key, value in replacements.items(): scope.enter_context(patch.object(harness, key, value))
            scope.enter_context(patch.object(harness.subprocess, 'Popen', popen))
            scope.enter_context(patch.object(harness.subprocess, 'run', client))
            scope.enter_context(patch.object(harness.urllib.request, 'urlopen',
                lambda *args, **kwargs: nullcontext(SimpleNamespace(status=200,
                    read=lambda maximum: b'{"data":[{"id":"Qwen3.5-9B"}]}'))))
            scope.enter_context(patch('sys.argv', ['run.py', '--attempt', '1', '--client', str(CLIENT),
                                                  '--warmup-tokens', '512']))
            with redirect_stdout(io.StringIO()), self.assertRaises(SystemExit) as stopped:
                harness.main()
            record = json.loads((base/'physical-1/execution.json').read_bytes())
            self.assertEqual(native.stdin.getvalue(), b'stop\n')
            self.assertFalse((base/'physical-1/token.private').exists())
            self.assertEqual(calls.count('product-start'), 1)
            self.assertEqual(calls.count('supervisor-retired'), 1)
            self.assertEqual(calls[:3], ['product-start', 'tokenizer-8192', 'tokenizer-512'])
            return stopped.exception.code, record, calls

    def test_short_eos_warmup_then_exact8192_same_owned_session(self):
        code, record, calls = self.scenario()
        self.assertEqual(code, 0)
        self.assertEqual(calls[-3:], ['warmup-client', 'measured-client', 'supervisor-retired'])
        self.assertEqual(record['warmupUsage']['completion_tokens'], 123)
        self.assertEqual(record['measuredUsage']['prompt_tokens'], 8192)
        self.assertEqual(record['warmupClientAttempts'], 1)
        self.assertEqual(record['measuredClientAttempts'], 1)

    def test_failed_warmup_aborts_measured_and_runs_cleanup(self):
        code, record, calls = self.scenario(warmup_status='failed')
        self.assertEqual(code, 1)
        self.assertNotIn('measured-client', calls)
        self.assertEqual(record['measuredClientAttempts'], 0)
        self.assertTrue(record['nativeProcessesAbsent'])
        self.assertTrue(record['journalsEmpty'])

    def test_zero_output_stop_aborts_measured(self):
        code, record, calls = self.scenario(warmup_outputs=0)
        self.assertEqual(code, 1)
        self.assertNotIn('measured-client', calls)

    def test_absent_content_eligibility_is_separate_from_http_pass(self):
        code, record, calls = self.scenario(warmup_status='no_content', warmup_outputs=1)
        self.assertEqual(code, 0)
        self.assertIn('measured-client', calls)
        self.assertFalse(record['normalHTTPRequestsAllPassed'])
        self.assertEqual(record['warmupClientExitCode'], 1)
        self.assertFalse(record['warmupEligibility']['normalClientPassed'])

    def test_measured_actual_input_count_mismatch_fails(self):
        code, record, calls = self.scenario(measured_count=8191)
        self.assertEqual(code, 1)
        self.assertIn('input count differs', record['error'])


if __name__ == '__main__': unittest.main()
