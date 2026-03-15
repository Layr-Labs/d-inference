"""Tests for dginf.client using respx to mock httpx."""

from __future__ import annotations

import json

import httpx
import pytest
import respx

from dginf.client import DGInf
from dginf.errors import (
    AuthenticationError,
    DGInfError,
    ProviderError,
    ProviderUnavailableError,
    RequestError,
)
from dginf.types import ChatCompletion, ChatCompletionChunk, ModelList

BASE = "http://test-coordinator:8080"
KEY = "test-api-key"

COMPLETION_JSON = {
    "id": "chatcmpl-123",
    "object": "chat.completion",
    "created": 1700000000,
    "model": "qwen3.5-9b",
    "choices": [
        {
            "index": 0,
            "message": {"role": "assistant", "content": "Hello!"},
            "finish_reason": "stop",
        }
    ],
    "usage": {
        "prompt_tokens": 5,
        "completion_tokens": 2,
        "total_tokens": 7,
    },
}

SSE_STREAM = (
    "data: " + json.dumps({
        "id": "chatcmpl-123",
        "object": "chat.completion.chunk",
        "created": 1700000000,
        "model": "qwen3.5-9b",
        "choices": [{"index": 0, "delta": {"role": "assistant", "content": ""}, "finish_reason": None}],
    }) + "\n\n"
    "data: " + json.dumps({
        "id": "chatcmpl-123",
        "object": "chat.completion.chunk",
        "created": 1700000000,
        "model": "qwen3.5-9b",
        "choices": [{"index": 0, "delta": {"content": "Hi"}, "finish_reason": None}],
    }) + "\n\n"
    "data: " + json.dumps({
        "id": "chatcmpl-123",
        "object": "chat.completion.chunk",
        "created": 1700000000,
        "model": "qwen3.5-9b",
        "choices": [{"index": 0, "delta": {"content": " there!"}, "finish_reason": None}],
    }) + "\n\n"
    "data: " + json.dumps({
        "id": "chatcmpl-123",
        "object": "chat.completion.chunk",
        "created": 1700000000,
        "model": "qwen3.5-9b",
        "choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}],
    }) + "\n\n"
    "data: [DONE]\n\n"
)

MODELS_JSON = {
    "object": "list",
    "data": [
        {"id": "qwen3.5-9b", "object": "model", "created": 0, "owned_by": "local"},
        {"id": "llama3-8b", "object": "model", "created": 0, "owned_by": "local"},
    ],
}


@pytest.fixture()
def client():
    c = DGInf(base_url=BASE, api_key=KEY)
    yield c
    c.close()


# ── Non-streaming completion ───────────────────────────────────────────────


@respx.mock
def test_chat_completion(client: DGInf) -> None:
    respx.post(f"{BASE}/v1/chat/completions").mock(
        return_value=httpx.Response(200, json=COMPLETION_JSON)
    )

    result = client.chat.completions.create(
        model="qwen3.5-9b",
        messages=[{"role": "user", "content": "hi"}],
    )

    assert isinstance(result, ChatCompletion)
    assert result.id == "chatcmpl-123"
    assert result.choices[0].message.content == "Hello!"
    assert result.choices[0].finish_reason == "stop"
    assert result.usage is not None
    assert result.usage.total_tokens == 7


# ── Streaming completion ──────────────────────────────────────────────────


@respx.mock
def test_chat_completion_streaming(client: DGInf) -> None:
    respx.post(f"{BASE}/v1/chat/completions").mock(
        return_value=httpx.Response(
            200,
            content=SSE_STREAM.encode(),
            headers={"content-type": "text/event-stream"},
        )
    )

    chunks: list[ChatCompletionChunk] = []
    for chunk in client.chat.completions.create(
        model="qwen3.5-9b",
        messages=[{"role": "user", "content": "hi"}],
        stream=True,
    ):
        chunks.append(chunk)

    assert len(chunks) == 4
    assert chunks[0].choices[0].delta.role == "assistant"
    assert chunks[1].choices[0].delta.content == "Hi"
    assert chunks[2].choices[0].delta.content == " there!"
    assert chunks[3].choices[0].finish_reason == "stop"


# ── Models list ────────────────────────────────────────────────────────────


@respx.mock
def test_models_list(client: DGInf) -> None:
    respx.get(f"{BASE}/v1/models").mock(
        return_value=httpx.Response(200, json=MODELS_JSON)
    )

    result = client.models.list()

    assert isinstance(result, ModelList)
    assert len(result.data) == 2
    assert result.data[0].id == "qwen3.5-9b"
    assert result.data[1].id == "llama3-8b"


# ── Error mapping ─────────────────────────────────────────────────────────


@respx.mock
def test_401_raises_authentication_error(client: DGInf) -> None:
    respx.post(f"{BASE}/v1/chat/completions").mock(
        return_value=httpx.Response(401, text="Unauthorized")
    )

    with pytest.raises(AuthenticationError) as exc_info:
        client.chat.completions.create(
            model="qwen3.5-9b",
            messages=[{"role": "user", "content": "hi"}],
        )

    assert exc_info.value.status_code == 401


@respx.mock
def test_503_raises_provider_unavailable(client: DGInf) -> None:
    respx.post(f"{BASE}/v1/chat/completions").mock(
        return_value=httpx.Response(503, text="Service Unavailable")
    )

    with pytest.raises(ProviderUnavailableError) as exc_info:
        client.chat.completions.create(
            model="qwen3.5-9b",
            messages=[{"role": "user", "content": "hi"}],
        )

    assert exc_info.value.status_code == 503


@respx.mock
def test_502_raises_provider_error(client: DGInf) -> None:
    respx.post(f"{BASE}/v1/chat/completions").mock(
        return_value=httpx.Response(502, text="Bad Gateway")
    )

    with pytest.raises(ProviderError) as exc_info:
        client.chat.completions.create(
            model="qwen3.5-9b",
            messages=[{"role": "user", "content": "hi"}],
        )

    assert exc_info.value.status_code == 502


@respx.mock
def test_other_http_error_raises_dginf_error(client: DGInf) -> None:
    respx.post(f"{BASE}/v1/chat/completions").mock(
        return_value=httpx.Response(500, text="Internal Server Error")
    )

    with pytest.raises(DGInfError) as exc_info:
        client.chat.completions.create(
            model="qwen3.5-9b",
            messages=[{"role": "user", "content": "hi"}],
        )

    assert exc_info.value.status_code == 500


@respx.mock
def test_connection_error_raises_request_error(client: DGInf) -> None:
    respx.post(f"{BASE}/v1/chat/completions").mock(
        side_effect=httpx.ConnectError("Connection refused")
    )

    with pytest.raises(RequestError):
        client.chat.completions.create(
            model="qwen3.5-9b",
            messages=[{"role": "user", "content": "hi"}],
        )


# ── Client requires base_url and api_key ──────────────────────────────────


def test_missing_base_url_raises() -> None:
    with pytest.raises(DGInfError, match="base_url"):
        DGInf(api_key="k")


def test_missing_api_key_raises() -> None:
    with pytest.raises(DGInfError, match="api_key"):
        DGInf(base_url="http://x")


# ── Context manager ───────────────────────────────────────────────────────


@respx.mock
def test_context_manager() -> None:
    respx.get(f"{BASE}/v1/models").mock(
        return_value=httpx.Response(200, json=MODELS_JSON)
    )

    with DGInf(base_url=BASE, api_key=KEY) as client:
        result = client.models.list()
        assert len(result.data) == 2


# ── Payment endpoints ─────────────────────────────────────────────────────


DEPOSIT_RESPONSE = {
    "status": "deposited",
    "wallet_address": "0x1234567890abcdef1234567890abcdef12345678",
    "amount_usd": "10.00",
    "amount_micro_usd": 10_000_000,
    "balance_micro_usd": 10_000_000,
}

BALANCE_RESPONSE = {
    "balance_micro_usd": 10_000_000,
    "balance_usd": "10.000000",
}

USAGE_RESPONSE = {
    "usage": [
        {
            "job_id": "job-abc-123",
            "model": "qwen3.5-9b",
            "prompt_tokens": 50,
            "completion_tokens": 100,
            "cost_micro_usd": 1000,
            "timestamp": "2026-03-14T12:00:00Z",
        },
        {
            "job_id": "job-def-456",
            "model": "llama3-8b",
            "prompt_tokens": 30,
            "completion_tokens": 200,
            "cost_micro_usd": 1000,
            "timestamp": "2026-03-14T12:05:00Z",
        },
    ]
}


@respx.mock
def test_payments_deposit(client: DGInf) -> None:
    respx.post(f"{BASE}/v1/payments/deposit").mock(
        return_value=httpx.Response(200, json=DEPOSIT_RESPONSE)
    )

    result = client.payments.deposit(
        wallet_address="0x1234567890abcdef1234567890abcdef12345678",
        amount_usd="10.00",
    )

    assert result["status"] == "deposited"
    assert result["amount_micro_usd"] == 10_000_000
    assert result["balance_micro_usd"] == 10_000_000


@respx.mock
def test_payments_balance(client: DGInf) -> None:
    respx.get(f"{BASE}/v1/payments/balance").mock(
        return_value=httpx.Response(200, json=BALANCE_RESPONSE)
    )

    result = client.payments.balance()

    assert result["balance_micro_usd"] == 10_000_000
    assert result["balance_usd"] == "10.000000"


@respx.mock
def test_payments_usage(client: DGInf) -> None:
    respx.get(f"{BASE}/v1/payments/usage").mock(
        return_value=httpx.Response(200, json=USAGE_RESPONSE)
    )

    entries = client.payments.usage()

    assert len(entries) == 2
    assert entries[0]["job_id"] == "job-abc-123"
    assert entries[0]["model"] == "qwen3.5-9b"
    assert entries[0]["cost_micro_usd"] == 1000
    assert entries[1]["job_id"] == "job-def-456"


@respx.mock
def test_payments_usage_empty(client: DGInf) -> None:
    respx.get(f"{BASE}/v1/payments/usage").mock(
        return_value=httpx.Response(200, json={"usage": []})
    )

    entries = client.payments.usage()
    assert entries == []


@respx.mock
def test_payments_deposit_auth_error(client: DGInf) -> None:
    respx.post(f"{BASE}/v1/payments/deposit").mock(
        return_value=httpx.Response(401, text="Unauthorized")
    )

    with pytest.raises(AuthenticationError):
        client.payments.deposit(
            wallet_address="0x1234",
            amount_usd="10.00",
        )


@respx.mock
def test_payments_balance_connection_error(client: DGInf) -> None:
    respx.get(f"{BASE}/v1/payments/balance").mock(
        side_effect=httpx.ConnectError("Connection refused")
    )

    with pytest.raises(RequestError):
        client.payments.balance()


# ── Trust info in response ──────────────────────────────────────────────


@respx.mock
def test_trust_level_in_response(client: DGInf) -> None:
    """Verify trust info is extracted from response headers."""
    respx.post(f"{BASE}/v1/chat/completions").mock(
        return_value=httpx.Response(
            200,
            json=COMPLETION_JSON,
            headers={
                "X-Provider-Attested": "true",
                "X-Provider-Trust-Level": "self_signed",
            },
        )
    )

    result = client.chat.completions.create(
        model="qwen3.5-9b",
        messages=[{"role": "user", "content": "hi"}],
    )

    assert isinstance(result, ChatCompletion)
    assert result.provider_attested is True
    assert result.provider_trust_level == "self_signed"


@respx.mock
def test_trust_level_none_in_response(client: DGInf) -> None:
    """Verify trust info works when provider is not attested."""
    respx.post(f"{BASE}/v1/chat/completions").mock(
        return_value=httpx.Response(
            200,
            json=COMPLETION_JSON,
            headers={
                "X-Provider-Attested": "false",
                "X-Provider-Trust-Level": "none",
            },
        )
    )

    result = client.chat.completions.create(
        model="qwen3.5-9b",
        messages=[{"role": "user", "content": "hi"}],
    )

    assert result.provider_attested is False
    assert result.provider_trust_level == "none"


@respx.mock
def test_trust_level_missing_headers(client: DGInf) -> None:
    """When trust headers are absent, fields should be None."""
    respx.post(f"{BASE}/v1/chat/completions").mock(
        return_value=httpx.Response(200, json=COMPLETION_JSON)
    )

    result = client.chat.completions.create(
        model="qwen3.5-9b",
        messages=[{"role": "user", "content": "hi"}],
    )

    assert result.provider_attested is None
    assert result.provider_trust_level is None
