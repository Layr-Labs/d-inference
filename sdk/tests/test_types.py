"""Tests for dginf.types — Pydantic model serialization round-trips."""

from __future__ import annotations

from dginf.types import (
    ChatCompletion,
    ChatCompletionChunk,
    ChatMessage,
    Choice,
    DeltaMessage,
    Model,
    ModelList,
    StreamChoice,
    Usage,
)


def test_chat_completion_round_trip() -> None:
    raw = {
        "id": "chatcmpl-abc",
        "object": "chat.completion",
        "created": 1700000000,
        "model": "qwen3.5-9b",
        "choices": [
            {
                "index": 0,
                "message": {"role": "assistant", "content": "Hello"},
                "finish_reason": "stop",
            }
        ],
        "usage": {
            "prompt_tokens": 10,
            "completion_tokens": 5,
            "total_tokens": 15,
        },
    }

    obj = ChatCompletion.model_validate(raw)
    assert obj.id == "chatcmpl-abc"
    assert obj.choices[0].message.content == "Hello"
    assert obj.usage is not None
    assert obj.usage.total_tokens == 15

    # Round-trip through dict
    dumped = obj.model_dump()
    restored = ChatCompletion.model_validate(dumped)
    assert restored == obj


def test_chat_completion_chunk_round_trip() -> None:
    raw = {
        "id": "chatcmpl-abc",
        "object": "chat.completion.chunk",
        "created": 1700000000,
        "model": "qwen3.5-9b",
        "choices": [
            {
                "index": 0,
                "delta": {"content": "Hi"},
                "finish_reason": None,
            }
        ],
    }

    obj = ChatCompletionChunk.model_validate(raw)
    assert obj.choices[0].delta.content == "Hi"
    assert obj.choices[0].finish_reason is None

    dumped = obj.model_dump()
    restored = ChatCompletionChunk.model_validate(dumped)
    assert restored == obj


def test_model_list_round_trip() -> None:
    raw = {
        "object": "list",
        "data": [
            {"id": "qwen3.5-9b", "object": "model", "created": 0, "owned_by": "local"},
            {"id": "llama3-8b", "object": "model", "created": 0, "owned_by": "local"},
        ],
    }

    obj = ModelList.model_validate(raw)
    assert len(obj.data) == 2
    assert obj.data[0].id == "qwen3.5-9b"

    dumped = obj.model_dump()
    restored = ModelList.model_validate(dumped)
    assert restored == obj


def test_chat_completion_without_usage() -> None:
    """Usage is optional in some responses."""
    raw = {
        "id": "chatcmpl-xyz",
        "object": "chat.completion",
        "created": 1700000000,
        "model": "test",
        "choices": [
            {
                "index": 0,
                "message": {"role": "assistant", "content": "ok"},
                "finish_reason": "stop",
            }
        ],
    }

    obj = ChatCompletion.model_validate(raw)
    assert obj.usage is None


def test_delta_message_partial() -> None:
    """Delta messages can have only content, only role, or neither."""
    d1 = DeltaMessage.model_validate({"role": "assistant"})
    assert d1.role == "assistant"
    assert d1.content is None

    d2 = DeltaMessage.model_validate({"content": "hi"})
    assert d2.role is None
    assert d2.content == "hi"

    d3 = DeltaMessage.model_validate({})
    assert d3.role is None
    assert d3.content is None


def test_empty_model_list() -> None:
    obj = ModelList.model_validate({"object": "list", "data": []})
    assert obj.data == []

    obj2 = ModelList.model_validate({"object": "list"})
    assert obj2.data == []


def test_chat_completion_with_trust_info() -> None:
    """ChatCompletion should support trust fields."""
    raw = {
        "id": "chatcmpl-trust",
        "object": "chat.completion",
        "created": 1700000000,
        "model": "qwen3.5-9b",
        "choices": [
            {
                "index": 0,
                "message": {"role": "assistant", "content": "ok"},
                "finish_reason": "stop",
            }
        ],
        "provider_attested": True,
        "provider_trust_level": "self_signed",
    }

    obj = ChatCompletion.model_validate(raw)
    assert obj.provider_attested is True
    assert obj.provider_trust_level == "self_signed"

    dumped = obj.model_dump()
    assert dumped["provider_attested"] is True
    assert dumped["provider_trust_level"] == "self_signed"


def test_chat_completion_without_trust_info() -> None:
    """Trust fields should default to None when absent."""
    raw = {
        "id": "chatcmpl-no-trust",
        "object": "chat.completion",
        "created": 1700000000,
        "model": "test",
        "choices": [
            {
                "index": 0,
                "message": {"role": "assistant", "content": "ok"},
                "finish_reason": "stop",
            }
        ],
    }

    obj = ChatCompletion.model_validate(raw)
    assert obj.provider_attested is None
    assert obj.provider_trust_level is None


def test_model_with_metadata() -> None:
    """Model should support metadata with trust_level."""
    from dginf.types import ModelMetadata

    raw = {
        "id": "qwen3.5-9b",
        "object": "model",
        "created": 0,
        "owned_by": "dginf",
        "metadata": {
            "model_type": "qwen3",
            "quantization": "4bit",
            "provider_count": 2,
            "attested_providers": 1,
            "trust_level": "self_signed",
        },
    }

    obj = Model.model_validate(raw)
    assert obj.metadata is not None
    assert obj.metadata.trust_level == "self_signed"
    assert obj.metadata.attested_providers == 1
    assert obj.metadata.provider_count == 2


def test_model_without_metadata() -> None:
    """Model should work without metadata (backward compatible)."""
    raw = {
        "id": "test-model",
        "object": "model",
    }

    obj = Model.model_validate(raw)
    assert obj.metadata is None
