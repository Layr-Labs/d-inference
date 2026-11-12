"""Pure CPU: pinned inputs, actual parser contracts, no network or model execution."""
import copy
import hashlib
import json
from pathlib import Path
import tempfile
import unittest
from receipt_fixture import CLIENT, receipt
from warmup_inputs import bounded_bytes, client_files, workloads
from warmup_result import validate

PROMPT_SHA = hashlib.sha256(b'fixture').hexdigest()


class WarmupChecks(unittest.TestCase):
    def check(self, value, code=0):
        return validate(value, 512, PROMPT_SHA, code)

    def test_exact_frozen_workloads_and_client(self):
        for count in (512, 1024):
            value = workloads(count)
            self.assertEqual(len(json.loads(value.warmup_expected_token_ids.read_bytes())), count)
            self.assertEqual(len(json.loads(value.expected_token_ids.read_bytes())), 8192)
            request = json.loads(value.pinned_files[3].read_bytes())
            self.assertEqual(request['max_tokens'], 128)
            self.assertIs(request['enable_thinking'], False)
            self.assertEqual(request['reasoning_parser'], 'qwen3')
        self.assertEqual(len(client_files(CLIENT)), 6)

    def test_unsupported_workloads(self):
        for value in (0, 511, 513, 4096, 8192, True, '512', 512.0):
            with self.subTest(value=value), self.assertRaises(ValueError):
                workloads(value)

    def test_stop_includes_reported_eos_token(self):
        for count in (1, 123, 128):
            result = self.check(receipt(outputs=count, finish='stop'))
            self.assertEqual(result['actualUsage']['completion_tokens'], count)
            self.assertTrue(result['eligible'])

    def test_length_requires_requested_128(self):
        self.assertTrue(self.check(receipt())['eligible'])
        with self.assertRaises(ValueError):
            self.check(receipt(outputs=127))

    def test_zero_stop_does_not_prove_warmup(self):
        for content in (False, True):
            with self.subTest(content=content), self.assertRaises(ValueError):
                self.check(receipt(outputs=0, finish='stop', content=content), 0 if content else 1)

    def test_no_content_stop_stays_normal_client_failure(self):
        value = receipt(outputs=1, finish='stop', content=False)
        original = copy.deepcopy(value)
        result = self.check(value, 1)
        self.assertTrue(result['eligible'])
        self.assertFalse(result['normalClientPassed'])
        self.assertEqual(result['normalClientStatus'], 'no_content')
        self.assertFalse(result['contentSLA']['reported_prompt_tokens']['request_passed'])
        self.assertEqual(value, original)

    def test_content_sla_miss_is_retained(self):
        result = self.check(receipt(missed=True), 1)
        self.assertTrue(result['eligible'])
        self.assertFalse(result['normalClientPassed'])
        self.assertFalse(result['contentSLA']['reported_prompt_tokens']['request_passed'])

    def test_no_content_length_is_not_eos_stop(self):
        with self.assertRaises(ValueError):
            self.check(receipt(content=False), 1)

    def test_invalid_usage(self):
        for updates in ({'prompt_tokens': 511}, {'prompt_tokens': True},
                        {'completion_tokens': 129}, {'completion_tokens': False},
                        {'total_tokens': 639}):
            value = receipt()
            value['measurement']['usage'].update(updates)
            with self.subTest(updates=updates), self.assertRaises(ValueError):
                self.check(value)

    def test_missing_terminal_or_capture(self):
        for key in ('done', 'stream_terminal_complete'):
            value = receipt(); value['measurement'][key] = False
            with self.subTest(key=key), self.assertRaises(ValueError):
                self.check(value)
        for updates in ({'capture_complete': False}, {'http_status': 503},
                        {'capture_error': 'OSError'}, {'cleanup_errors': ['OSError']}):
            value = receipt(); value.update(updates)
            with self.subTest(updates=updates), self.assertRaises(ValueError):
                self.check(value)

    def test_transport_timeout_and_exit_mismatch(self):
        value = receipt(); value['error'] = dict(type='TimeoutError', code='absolute_timeout')
        with self.assertRaises(ValueError): self.check(value)
        with self.assertRaises(ValueError): self.check(receipt(), 1)
        value = receipt(content=False, finish='stop', outputs=1)
        value['error'] = dict(type='OSError', code='request_failed')
        with self.assertRaises(ValueError): self.check(value, 1)

    def test_input_and_settings_mismatch(self):
        value = receipt(); value['request_settings']['max_tokens'] = 64
        with self.assertRaises(ValueError): self.check(value)
        value = receipt(); value['prompt_utf8_sha256'] = '0' * 64
        with self.assertRaises(ValueError): self.check(value)
        value = receipt(); value['measurement']['declared_prompt_tokens'] = 1024
        with self.assertRaises(ValueError): self.check(value)

    def test_bounded_regular_file_read(self):
        with tempfile.TemporaryDirectory() as name:
            root = Path(name); path = root / 'bytes'; path.write_bytes(b'1234')
            self.assertEqual(bounded_bytes(path, 4), b'1234')
            with self.assertRaises(ValueError): bounded_bytes(path, 3)
            link = root / 'link'; link.symlink_to(path)
            with self.assertRaises(OSError): bounded_bytes(link, 4)
            with self.assertRaises(ValueError): bounded_bytes(root, 65536)


if __name__ == '__main__': unittest.main()
