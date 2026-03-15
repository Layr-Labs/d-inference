"""DGInf client — OpenAI-compatible interface to the DGInf coordinator.

This module provides the main DGInf client class, which mirrors the OpenAI
Python client's interface (client.chat.completions.create, client.models.list,
etc.) so it can serve as a drop-in replacement.

Trust model:
    The DGInf coordinator runs in a GCP Confidential VM with AMD SEV-SNP,
    providing hardware-encrypted memory. Consumer traffic arrives over standard
    HTTPS/TLS — the coordinator is a trusted intermediary that can read requests
    for routing purposes. The coordinator never logs prompt content. Encryption
    to providers (when needed) is handled by the coordinator, not the consumer.

Usage::

    from dginf import DGInf

    client = DGInf(base_url="https://coordinator.dginf.io", api_key="dginf-...")
    resp = client.chat.completions.create(
        model="qwen3.5-9b",
        messages=[{"role": "user", "content": "Hello!"}],
    )
    print(resp.choices[0].message.content)
"""

from __future__ import annotations

import json
from collections.abc import Iterator
from typing import Any

import httpx

from dginf.config import load_config
from dginf.errors import (
    AuthenticationError,
    DGInfError,
    ProviderError,
    ProviderUnavailableError,
    RequestError,
)
from dginf.types import ChatCompletion, ChatCompletionChunk, ModelList


def _raise_for_status(response: httpx.Response) -> None:
    """Map HTTP error codes to typed DGInf exceptions.

    This centralizes error handling so that callers get specific exception
    types they can catch (e.g., AuthenticationError for 401, ProviderError
    for 502) rather than generic HTTP errors.
    """
    if response.is_success:
        return

    body = response.text
    code = response.status_code

    if code == 401:
        raise AuthenticationError(body=body)
    if code == 502:
        raise ProviderError(body=body)
    if code == 503:
        raise ProviderUnavailableError(body=body)

    raise DGInfError(
        f"HTTP {code}: {body}",
        status_code=code,
        body=body,
    )


def _iter_sse_lines(response: httpx.Response) -> Iterator[str]:
    """Yield SSE data payloads from a streaming httpx response.

    Server-Sent Events (SSE) consist of lines prefixed with "data: ".
    This generator filters out empty lines, comments (lines starting with ":"),
    and the terminal "[DONE]" sentinel, yielding only the JSON payload strings.
    """
    for line in response.iter_lines():
        # Skip empty lines and comments
        if not line or line.startswith(":"):
            continue
        if line.startswith("data: "):
            payload = line[len("data: "):]
            if payload.strip() == "[DONE]":
                return
            yield payload


def _attach_trust_info(
    completion: ChatCompletion,
    response: httpx.Response,
) -> ChatCompletion:
    """Extract provider attestation info from response headers.

    The coordinator sets these headers to communicate the trust properties
    of the provider that served the request:
        - X-Provider-Attested: "true" if the provider's Secure Enclave
          attestation was verified successfully.
        - X-Provider-Trust-Level: one of "none", "self_signed", or "hardware"
          indicating the attestation verification depth.

    These fields are attached to the ChatCompletion so consumers can make
    trust-based decisions (e.g., only accept results from attested providers).
    """
    attested_header = response.headers.get("X-Provider-Attested")
    if attested_header is not None:
        completion.provider_attested = attested_header.lower() == "true"

    trust_header = response.headers.get("X-Provider-Trust-Level")
    if trust_header is not None:
        completion.provider_trust_level = trust_header

    return completion


# ── Namespace classes (mirror OpenAI's client.chat.completions.create) ─────


class CompletionsNamespace:
    """Provides ``client.chat.completions.create(...)``.

    This namespace mirrors the OpenAI Python client's interface for chat
    completions. It supports both streaming and non-streaming modes.

    The consumer sends plain JSON over HTTPS to the coordinator. No client-side
    encryption is needed because the coordinator runs in a Confidential VM
    (AMD SEV-SNP) — TLS to the Confidential VM is the trust boundary.
    """

    def __init__(self, http: httpx.Client) -> None:
        self._http = http

    def create(
        self,
        *,
        model: str,
        messages: list[dict[str, Any]],
        stream: bool = False,
        **kwargs: Any,
    ) -> ChatCompletion | Iterator[ChatCompletionChunk]:
        """Create a chat completion (streaming or non-streaming).

        The request is sent as plain JSON over HTTPS/TLS to the coordinator
        (Confidential VM). The coordinator reads the request for routing,
        selects an appropriate provider, and forwards the request.

        Args:
            model: The model to use for inference (e.g., "qwen3.5-9b").
            messages: List of chat messages in OpenAI format, each with
                "role" and "content" keys.
            stream: If True, returns an iterator of ChatCompletionChunk
                objects. If False, returns a single ChatCompletion.
            **kwargs: Additional parameters passed to the API (e.g.,
                temperature, max_tokens).

        Returns:
            ChatCompletion for non-streaming, or Iterator[ChatCompletionChunk]
            for streaming mode.

        Raises:
            AuthenticationError: If the API key is invalid (HTTP 401).
            ProviderUnavailableError: If no provider has the model (HTTP 503).
            ProviderError: If the provider returned an error (HTTP 502).
            RequestError: On connection/timeout failures.
        """
        body: dict[str, Any] = {
            "model": model,
            "messages": messages,
            "stream": stream,
            **kwargs,
        }

        if not stream:
            return self._create_sync(body)
        return self._create_stream(body)

    # -- internal helpers ----------------------------------------------------

    def _create_sync(self, body: dict[str, Any]) -> ChatCompletion:
        """Send a non-streaming completion request and parse the response."""
        try:
            response = self._http.post("/v1/chat/completions", json=body)
        except httpx.HTTPError as exc:
            raise RequestError(str(exc), cause=exc) from exc

        _raise_for_status(response)
        result = ChatCompletion.model_validate(response.json())
        # Populate trust fields from response headers
        result = _attach_trust_info(result, response)
        return result

    def _create_stream(self, body: dict[str, Any]) -> Iterator[ChatCompletionChunk]:
        """Send a streaming completion request and yield SSE chunks.

        The response is an SSE (Server-Sent Events) stream where each event
        contains a JSON-encoded ChatCompletionChunk. The stream terminates
        with a "data: [DONE]" sentinel.
        """
        try:
            with self._http.stream("POST", "/v1/chat/completions", json=body) as response:
                _raise_for_status(response)
                for payload in _iter_sse_lines(response):
                    chunk = ChatCompletionChunk.model_validate(json.loads(payload))
                    yield chunk
        except httpx.HTTPError as exc:
            raise RequestError(str(exc), cause=exc) from exc


class ChatNamespace:
    """Provides ``client.chat.completions``.

    This intermediate namespace exists solely to mirror the OpenAI client's
    nesting structure: client.chat.completions.create(...).
    """

    def __init__(self, http: httpx.Client) -> None:
        self._completions = CompletionsNamespace(http)

    @property
    def completions(self) -> CompletionsNamespace:
        return self._completions


class ModelsNamespace:
    """Provides ``client.models.list()``.

    Lists all models available across connected providers. Each model entry
    includes attestation metadata (trust level, number of attested providers,
    Secure Enclave availability) to help consumers make informed choices.
    """

    def __init__(self, http: httpx.Client) -> None:
        self._http = http

    def list(self) -> ModelList:
        """List available models on the coordinator.

        Returns:
            ModelList containing all models currently available across
            connected providers, with attestation metadata.

        Raises:
            AuthenticationError: If the API key is invalid.
            RequestError: On connection/timeout failures.
        """
        try:
            response = self._http.get("/v1/models")
        except httpx.HTTPError as exc:
            raise RequestError(str(exc), cause=exc) from exc

        _raise_for_status(response)
        return ModelList.model_validate(response.json())


class PaymentsNamespace:
    """Provides ``client.payments.deposit()``, ``.balance()``, and ``.usage()``.

    DGInf uses a micro-USD ledger for tracking inference costs. Consumers
    deposit funds (MVP: trust-based ledger credit; production: verified
    pathUSD stablecoin transfer on Tempo blockchain via Viem), and the
    coordinator debits per-request based on token usage.

    All monetary amounts are in micro-USD (1 USD = 1,000,000 micro-USD),
    which maps 1:1 to pathUSD's 6-decimal on-chain representation.
    """

    def __init__(self, http: httpx.Client) -> None:
        self._http = http

    def deposit(self, wallet_address: str, amount_usd: str) -> dict[str, Any]:
        """Deposit funds to the ledger (MVP: trust-based, no on-chain verification).

        In production, the coordinator would verify a pathUSD transfer on Tempo
        blockchain (via Viem) before crediting the balance.

        Args:
            wallet_address: Ethereum-format hex address (0x...).
            amount_usd: Amount in USD as a string (e.g. "10.00").

        Returns:
            Dict with status, wallet_address, amounts, and current balance.

        Raises:
            AuthenticationError: If the API key is invalid.
            RequestError: On connection/timeout failures.
        """
        try:
            response = self._http.post(
                "/v1/payments/deposit",
                json={"wallet_address": wallet_address, "amount_usd": amount_usd},
            )
        except httpx.HTTPError as exc:
            raise RequestError(str(exc), cause=exc) from exc

        _raise_for_status(response)
        return response.json()

    def balance(self) -> dict[str, Any]:
        """Get current balance in micro-USD and USD.

        Returns:
            Dict with balance_micro_usd (int) and balance_usd (str).

        Raises:
            AuthenticationError: If the API key is invalid.
            RequestError: On connection/timeout failures.
        """
        try:
            response = self._http.get("/v1/payments/balance")
        except httpx.HTTPError as exc:
            raise RequestError(str(exc), cause=exc) from exc

        _raise_for_status(response)
        return response.json()

    def usage(self) -> list[dict[str, Any]]:
        """Get usage history with costs.

        Returns:
            List of usage entries, each containing job_id, model,
            prompt_tokens, completion_tokens, cost_micro_usd, and timestamp.

        Raises:
            AuthenticationError: If the API key is invalid.
            RequestError: On connection/timeout failures.
        """
        try:
            response = self._http.get("/v1/payments/usage")
        except httpx.HTTPError as exc:
            raise RequestError(str(exc), cause=exc) from exc

        _raise_for_status(response)
        data = response.json()
        return data.get("usage", [])


# ── Main client ────────────────────────────────────────────────────────────


class DGInf:
    """DGInf consumer client — drop-in replacement for the OpenAI Python client.

    Connects to a DGInf coordinator over HTTPS/TLS. The coordinator runs in a
    GCP Confidential VM (AMD SEV-SNP, hardware-encrypted memory), so standard
    TLS is sufficient — no client-side encryption is needed.

    The coordinator reads requests for routing purposes, selects an appropriate
    attested provider, forwards the request, and returns the response. Prompt
    content is never logged by the coordinator.

    Usage::

        client = DGInf(base_url="https://coordinator.dginf.io", api_key="dginf-...")
        resp = client.chat.completions.create(
            model="qwen3.5-9b",
            messages=[{"role": "user", "content": "Hello!"}],
        )
        print(resp.choices[0].message.content)

    Configuration can be provided directly or loaded from ~/.dginf/config.toml
    (created via ``dginf configure``).

    Args:
        base_url: Coordinator URL (e.g., "https://coordinator.dginf.io").
            Falls back to config file if not provided.
        api_key: DGInf API key (e.g., "dginf-..."). Falls back to config
            file if not provided.
        timeout: HTTP request timeout in seconds (default: 120s, generous
            for inference which can take time on large models).
    """

    def __init__(
        self,
        base_url: str | None = None,
        api_key: str | None = None,
        timeout: float = 120.0,
    ) -> None:
        # Fall back to config file when args are not provided
        if base_url is None or api_key is None:
            cfg = load_config() or {}
            base_url = base_url or cfg.get("base_url")
            api_key = api_key or cfg.get("api_key")

        if not base_url:
            raise DGInfError(
                "base_url is required — pass it directly or run `dginf configure`"
            )
        if not api_key:
            raise DGInfError(
                "api_key is required — pass it directly or run `dginf configure`"
            )

        self._http = httpx.Client(
            base_url=base_url,
            headers={"Authorization": f"Bearer {api_key}"},
            timeout=timeout,
        )

        self._chat = ChatNamespace(self._http)
        self._models = ModelsNamespace(self._http)
        self._payments = PaymentsNamespace(self._http)

    # -- public namespaces ---------------------------------------------------

    @property
    def chat(self) -> ChatNamespace:
        """Access chat completion endpoints (client.chat.completions.create)."""
        return self._chat

    @property
    def models(self) -> ModelsNamespace:
        """Access model listing endpoints (client.models.list)."""
        return self._models

    @property
    def payments(self) -> PaymentsNamespace:
        """Access payment endpoints (deposit, balance, usage)."""
        return self._payments

    # -- lifecycle -----------------------------------------------------------

    def close(self) -> None:
        """Close the underlying HTTP client and release resources."""
        self._http.close()

    def __enter__(self) -> DGInf:
        return self

    def __exit__(self, *args: object) -> None:
        self.close()
