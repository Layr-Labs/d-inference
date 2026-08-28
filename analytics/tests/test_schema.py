import unittest

from darkbloom_analytics.schema import ValidationError, validate_event


def event(**overrides):
    value = {
        "schema_version": 1,
        "event_id": "event-1",
        "event_at": "2026-08-27T10:15:00Z",
        "event_name": "inference.completed",
        "process_epoch": "process-1",
        "job_id": "job-1",
        "trace_id": None,
        "serving_mode": "local",
        "model": "gemma-test",
        "outcome": "success",
        "error_class": None,
        "streaming": True,
        "prompt_tokens": 10,
        "completion_tokens": 5,
        "cached_prompt_tokens": 0,
        "queue_ms": 1.0,
        "ttft_ms": 20.0,
        "total_ms": 100.0,
        "decode_tps": 50.0,
        "earned_micro_usd": None,
        "kv_backend": "paged",
        "mtp_active": False,
    }
    value.update(overrides)
    return value


class SchemaTests(unittest.TestCase):
    def test_accepts_terminal_event(self):
        parsed = validate_event(event())
        self.assertEqual(parsed.hour.isoformat(), "2026-08-27T10:00:00+00:00")

    def test_rejects_prompt_content_structurally(self):
        with self.assertRaisesRegex(ValidationError, "privacy-forbidden"):
            validate_event(event(prompt="secret"))

    def test_rejects_unbounded_extension(self):
        with self.assertRaisesRegex(ValidationError, "unknown fields"):
            validate_event(event(attributes={"anything": "goes"}))

    def test_accepts_swift_omitted_nil_optionals(self):
        value = event()
        optional = {
            "trace_id",
            "model",
            "error_class",
            "queue_ms",
            "ttft_ms",
            "decode_tps",
            "earned_micro_usd",
            "kv_backend",
            "mtp_active",
        }
        for key in optional:
            value.pop(key)

        parsed = validate_event(value)

        self.assertTrue(optional.issubset(parsed.value))
        self.assertTrue(all(parsed.value[key] is None for key in optional))


if __name__ == "__main__":
    unittest.main()
