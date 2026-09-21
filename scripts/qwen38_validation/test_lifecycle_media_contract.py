"""Pure lifecycle-oracle tests; no model, network, credentials or files used."""
import json
from pathlib import Path
import unittest
from unittest.mock import patch
import lifecycle_matrix as lifecycle


def sample(proposed=10, accepted=8):
    return {"rows": [{"name": name, "labels": {}, "value": value} for name, value in [
        ("mtp_tokens_proposed_total", proposed), ("mtp_tokens_accepted_total", accepted)]]}


def valid_response():
    return {"http": 200, "body": json.dumps({"choices": [{"message": {"role": "assistant",
        "content": "A synthetic image."}, "finish_reason": "stop"}],
        "usage": {"prompt_tokens": 120, "completion_tokens": 4, "total_tokens": 124,
                  "prompt_tokens_details": {"cached_tokens": 0}}})}


class LifecycleMediaContractTests(unittest.TestCase):
    def setUp(self):
        self.matrix = lifecycle.Matrix(Path('/synthetic/not-created'))

    def test_supported_mode_requires_valid_200_output(self):
        with patch.object(lifecycle, 'exchange', return_value=valid_response()) as exchange, \
             patch.object(lifecycle, 'save'), patch.object(lifecycle, 'metrics', side_effect=[sample(), sample()]):
            result = self.matrix.image_supported()
            self.assertEqual(result['http'], 200)
            self.assertTrue(all(value == 0 for value in result['mtp_deltas'].values()))
            self.assertEqual(exchange.call_args.args[1]['reasoning'], {'enabled': False})

    def test_supported_mode_does_not_accept_a_refusal(self):
        with patch.object(lifecycle, 'exchange', return_value={'http': 400, 'body': '{}'}), \
             patch.object(lifecycle, 'save'), patch.object(lifecycle, 'metrics', return_value=sample()):
            with self.assertRaisesRegex(AssertionError, 'HTTP 400'):
                self.matrix.image_supported()

    def test_supported_media_must_not_speculate(self):
        with patch.object(lifecycle, 'exchange', return_value=valid_response()), \
             patch.object(lifecycle, 'save'), patch.object(lifecycle, 'metrics', side_effect=[sample(), sample(11)]):
            with self.assertRaisesRegex(AssertionError, 'unexpectedly speculated'):
                self.matrix.image_supported()

    def test_text_only_refusal_contract_is_preserved(self):
        refused = {'http': 400, 'body': json.dumps({'error': {'type': 'invalid_request_error',
                   'message': 'Media input is not supported.'}})}
        with patch.object(lifecycle, 'exchange', return_value=refused), patch.object(lifecycle, 'save'):
            self.assertEqual(self.matrix.image_refusal()['http'], 400)
        with patch.object(lifecycle, 'exchange', return_value=valid_response()), patch.object(lifecycle, 'save'):
            with self.assertRaisesRegex(AssertionError, 'unsupported image HTTP 200'):
                self.matrix.image_refusal()


if __name__ == '__main__':
    unittest.main()
