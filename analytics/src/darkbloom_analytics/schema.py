from __future__ import annotations

import datetime as dt
from dataclasses import dataclass
from typing import Any


SCHEMA_VERSION = 1
TERMINAL_EVENTS = {
    "inference.completed",
    "inference.failed",
    "inference.cancelled",
    "inference.rejected",
}
OUTCOMES = {"success", "failed", "cancelled", "rejected"}

FIELDS = {
    "schema_version",
    "event_id",
    "event_at",
    "event_name",
    "process_epoch",
    "job_id",
    "trace_id",
    "serving_mode",
    "model",
    "outcome",
    "error_class",
    "streaming",
    "prompt_tokens",
    "completion_tokens",
    "cached_prompt_tokens",
    "queue_ms",
    "ttft_ms",
    "total_ms",
    "decode_tps",
    "earned_micro_usd",
    "kv_backend",
    "mtp_active",
}

# Swift's synthesized Codable encoder omits nil optionals instead of writing
# explicit JSON nulls. Keep the wire schema strict, but normalize those omitted
# keys to null before validation and Parquet conversion.
OPTIONAL_FIELDS = {
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
REQUIRED_FIELDS = FIELDS - OPTIONAL_FIELDS

FORBIDDEN_FIELDS = {
    "prompt",
    "messages",
    "content",
    "completion",
    "response",
    "request_body",
    "api_key",
    "user",
    "user_id",
    "account_id",
    "error",
    "error_message",
    "stack_trace",
}


class ValidationError(ValueError):
    pass


@dataclass(frozen=True)
class ValidatedEvent:
    value: dict[str, Any]
    event_at: dt.datetime

    @property
    def hour(self) -> dt.datetime:
        return self.event_at.replace(minute=0, second=0, microsecond=0)


def validate_event(value: Any) -> ValidatedEvent:
    if not isinstance(value, dict):
        raise ValidationError("record must be a JSON object")
    keys = set(value)
    forbidden = keys & FORBIDDEN_FIELDS
    if forbidden:
        raise ValidationError(f"privacy-forbidden fields present: {sorted(forbidden)}")
    unknown = keys - FIELDS
    if unknown:
        raise ValidationError(f"unknown fields present: {sorted(unknown)}")
    missing = REQUIRED_FIELDS - keys
    if missing:
        raise ValidationError(f"required fields absent: {sorted(missing)}")
    value = {key: value.get(key) for key in FIELDS}
    if value["schema_version"] != SCHEMA_VERSION:
        raise ValidationError("unsupported schema_version")
    if value["event_name"] not in TERMINAL_EVENTS:
        raise ValidationError("event_name is not a terminal inference event")
    if value["outcome"] not in OUTCOMES:
        raise ValidationError("outcome is not in the bounded vocabulary")
    expected_event = (
        "inference.completed"
        if value["outcome"] == "success"
        else f"inference.{value['outcome']}"
    )
    if value["event_name"] != expected_event:
        raise ValidationError("event_name and outcome disagree")
    for key in ("event_id", "process_epoch", "job_id", "serving_mode"):
        _bounded_string(value[key], key, required=True)
    for key in ("trace_id", "model", "error_class", "kv_backend"):
        _bounded_string(value[key], key, required=False)
    if not isinstance(value["streaming"], bool):
        raise ValidationError("streaming must be boolean")
    if value["mtp_active"] is not None and not isinstance(value["mtp_active"], bool):
        raise ValidationError("mtp_active must be boolean or null")
    for key in ("prompt_tokens", "completion_tokens", "cached_prompt_tokens"):
        _nonnegative_integer(value[key], key)
    if value["earned_micro_usd"] is not None:
        _nonnegative_integer(value["earned_micro_usd"], "earned_micro_usd")
    for key in ("queue_ms", "ttft_ms", "total_ms", "decode_tps"):
        _nonnegative_number(value[key], key, nullable=key != "total_ms")

    raw_timestamp = value["event_at"]
    if not isinstance(raw_timestamp, str):
        raise ValidationError("event_at must be an ISO-8601 string")
    try:
        parsed = dt.datetime.fromisoformat(raw_timestamp.replace("Z", "+00:00"))
    except ValueError as exc:
        raise ValidationError("event_at is not valid ISO-8601") from exc
    if parsed.tzinfo is None:
        raise ValidationError("event_at must include a timezone")
    parsed = parsed.astimezone(dt.UTC)
    return ValidatedEvent(value=value, event_at=parsed)


def _bounded_string(value: Any, key: str, *, required: bool) -> None:
    if value is None and not required:
        return
    if not isinstance(value, str) or (required and not value):
        raise ValidationError(f"{key} must be a non-empty string")
    if len(value) > 512:
        raise ValidationError(f"{key} exceeds 512 characters")


def _nonnegative_integer(value: Any, key: str) -> None:
    if isinstance(value, bool) or not isinstance(value, int) or value < 0:
        raise ValidationError(f"{key} must be a nonnegative integer")


def _nonnegative_number(value: Any, key: str, *, nullable: bool) -> None:
    if value is None and nullable:
        return
    if isinstance(value, bool) or not isinstance(value, (int, float)) or value < 0:
        raise ValidationError(f"{key} must be a nonnegative number")
