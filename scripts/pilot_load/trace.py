from __future__ import annotations

import json
import random
from dataclasses import dataclass
from typing import Mapping

from .config import Profile


CONTRACT_SCENARIOS = (
    "health",
    "models_authorized",
    "models_unauthorized",
    "models_invalid_auth",
    "chat_unauthorized",
    "chat_stream",
    "chat_nonstream",
    "chat_alias_stream",
    "unknown_model",
    "malformed_json",
    "route_not_found",
    "method_not_allowed",
    "session_replacement",
    "hedge",
    "sent_unknown",
)


@dataclass(frozen=True)
class TraceRequest:
    index: int
    scenario: str
    method: str
    path: str
    headers: Mapping[str, str]
    body: bytes | None
    stream: bool
    peer_directive: str | None = None
    predicted_ttft_ms: float = 5.0
    expected_response_models: Mapping[str, str] | None = None


def deterministic_trace(
    profile: Profile,
    api_key: str,
    model: str,
    alias: str,
) -> tuple[TraceRequest, ...]:
    requests: list[TraceRequest] = []
    unsupported = set(profile.required_scenarios) - set(CONTRACT_SCENARIOS)
    if unsupported:
        raise ValueError(f"unsupported required scenarios: {sorted(unsupported)}")

    def add(
        scenario: str,
        method: str,
        path: str,
        body: bytes | None = None,
        *,
        authorized: bool = False,
        bearer: str | None = None,
        stream: bool = False,
        directive: str | None = None,
    ) -> None:
        headers: dict[str, str] = {}
        if body is not None:
            headers["content-type"] = "application/json"
        if authorized:
            headers["authorization"] = f"Bearer {api_key}"
        elif bearer is not None:
            headers["authorization"] = f"Bearer {bearer}"
        if method == "POST":
            headers["idempotency-key"] = f"objective9-{profile.seed}-{len(requests):08d}"
        expected_response_models = None
        if (
            authorized
            and path == "/v1/chat/completions"
            and scenario not in {"unknown_model", "malformed_json"}
            and body
        ):
            request_document = json.loads(body)
            requested_model = request_document.get("model")
            if isinstance(requested_model, str) and requested_model:
                expected_response_models = {
                    "go": requested_model,
                    "rust": model,
                }
        requests.append(
            TraceRequest(
                index=len(requests),
                scenario=scenario,
                method=method,
                path=path,
                headers=headers,
                body=body,
                stream=stream,
                peer_directive=directive,
                expected_response_models=expected_response_models,
            )
        )

    required = set(profile.required_scenarios)
    if "health" in required:
        add("health", "GET", "/health")
    if "models_authorized" in required:
        add("models_authorized", "GET", "/v1/models", authorized=True)
    if "models_unauthorized" in required:
        add("models_unauthorized", "GET", "/v1/models")
    if "models_invalid_auth" in required:
        add("models_invalid_auth", "GET", "/v1/models", bearer="objective9-invalid-key")
    if "chat_unauthorized" in required:
        add(
            "chat_unauthorized",
            "POST",
            "/v1/chat/completions",
            _chat_body(model, False, "unauthorized", profile.chunk_multiplier),
        )
    if "chat_stream" in required:
        add("chat_stream", "POST", "/v1/chat/completions", _chat_body(model, True, "stream", profile.chunk_multiplier), authorized=True, stream=True)
    if "chat_nonstream" in required:
        add("chat_nonstream", "POST", "/v1/chat/completions", _chat_body(model, False, "nonstream", profile.chunk_multiplier), authorized=True)
    if "chat_alias_stream" in required:
        add(
            "chat_alias_stream",
            "POST",
            "/v1/chat/completions",
            _chat_body(alias, True, "alias", profile.chunk_multiplier),
            authorized=True,
            stream=True,
        )
    if "unknown_model" in required:
        add("unknown_model", "POST", "/v1/chat/completions", _chat_body("objective9/missing", False, "missing", profile.chunk_multiplier), authorized=True)
    if "malformed_json" in required:
        add("malformed_json", "POST", "/v1/chat/completions", b"{", authorized=True)
    if "route_not_found" in required:
        add("route_not_found", "GET", "/v1/objective9/not-found", authorized=True)
    if "method_not_allowed" in required:
        add("method_not_allowed", "DELETE", "/v1/models", authorized=True)
    if "session_replacement" in required:
        add(
            "session_replacement",
            "POST",
            "/v1/chat/completions",
            _chat_body(alias, True, "replacement", profile.chunk_multiplier),
            authorized=True,
            stream=True,
            directive="session_replacement",
        )
    if "hedge" in required:
        add(
            "hedge",
            "POST",
            "/v1/chat/completions",
            _chat_body(alias, True, "hedge", profile.chunk_multiplier),
            authorized=True,
            stream=True,
            directive="hedge",
        )
    if "sent_unknown" in required:
        add(
            "sent_unknown",
            "POST",
            "/v1/chat/completions",
            _chat_body(alias, False, "sent-unknown", profile.chunk_multiplier),
            authorized=True,
            directive="sent_unknown",
        )

    randomizer = random.Random(profile.seed)
    for load_index in range(profile.request_count):
        streaming = load_index % 2 == 0
        selected_model = alias if load_index % 3 == 0 else model
        scenario = f"load_{load_index:06d}"
        body = _chat_body(
            selected_model,
            streaming,
            f"load-{randomizer.getrandbits(64):016x}",
            profile.chunk_multiplier,
        )
        add(scenario, "POST", "/v1/chat/completions", body, authorized=True, stream=streaming)
    return tuple(requests)


def _chat_body(model: str, stream: bool, marker: str, chunk_multiplier: int) -> bytes:
    return json.dumps(
        {
            "model": model,
            "messages": [{"role": "user", "content": f"objective-9 deterministic marker {marker}"}],
            "stream": stream,
            "max_tokens": 8 * chunk_multiplier,
            "pilot_chunk_multiplier": chunk_multiplier,
            "temperature": 0,
        },
        sort_keys=True,
        separators=(",", ":"),
    ).encode()
