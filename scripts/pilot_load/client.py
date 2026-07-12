from __future__ import annotations

import json
import random
import time
import urllib.error
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import dataclass, field, replace
from typing import Iterable

from .config import Profile
from .trace import TraceRequest


SEMANTIC_HEADERS = {
    "cache-control",
    "allow",
    "content-type",
    "retry-after",
    "www-authenticate",
    "x-eigen-sealed",
    "x-eigen-sealed-kid",
    "x-predicted-ttft-ms",
    "x-request-id",
    "x-timing",
}
SEMANTIC_HEADER_PREFIXES = ("x-provider-", "x-attestation-")


@dataclass
class Observation:
    implementation: str
    index: int
    scenario: str
    status: int
    headers: dict[str, str]
    body: bytes
    error: str | None
    stages_ms: dict[str, float]
    prediction_error_ms: float | None
    stream: bool = False
    prediction_source: str | None = None
    slow_consumer: bool = False
    expected_response_model: str | None = None


@dataclass
class TargetRun:
    implementation: str
    observations: list[Observation] = field(default_factory=list)
    elapsed_seconds: float = 0
    load_elapsed_seconds: float = 0
    concurrency_levels: list[int] = field(default_factory=list)
    cycles: int = 0

    @property
    def throughput_rps(self) -> float:
        if self.elapsed_seconds <= 0:
            return 0
        return len(self.observations) / self.elapsed_seconds


def execute_trace(
    profile: Profile,
    trace: tuple[TraceRequest, ...],
    go_url: str,
    rust_url: str,
    go_peer_control: str | None,
    rust_peer_control: str | None,
    timeout_seconds: float,
    control_token: str | None = None,
) -> tuple[TargetRun, TargetRun, list[str]]:
    go = TargetRun("go")
    rust = TargetRun("rust")
    skipped: list[str] = []
    required_count = len(profile.required_scenarios)
    deterministic = trace[:required_count]
    load_requests = trace[required_count:]
    started = time.monotonic()

    for request in deterministic:
        if request.peer_directive and (not go_peer_control or not rust_peer_control):
            skipped.append(request.scenario)
            continue
        if request.peer_directive:
            _control_peer(go_peer_control, request, profile, timeout_seconds, control_token)
            _control_peer(rust_peer_control, request, profile, timeout_seconds, control_token)
        with ThreadPoolExecutor(max_workers=2) as executor:
            futures = {
                executor.submit(_execute_one, "go", go_url, request, profile, timeout_seconds): go,
                executor.submit(_execute_one, "rust", rust_url, request, profile, timeout_seconds): rust,
            }
            for future, target in futures.items():
                target.observations.append(future.result())
        if request.peer_directive:
            _wait_peer_recovery(
                go_peer_control,
                go_url,
                profile.websocket_sessions,
                timeout_seconds,
            )
            _wait_peer_recovery(
                rust_peer_control,
                rust_url,
                profile.websocket_sessions,
                timeout_seconds,
            )

    load_started = time.monotonic()
    deadline = load_started + profile.duration_seconds
    cycle = 0
    next_index = len(deterministic)
    while load_requests and (cycle == 0 or (profile.soak and time.monotonic() < deadline)):
        cycled, next_index = _cycle_requests(load_requests, cycle, next_index)
        offset = 0
        for ramp_index, concurrency in enumerate(profile.concurrency_ramp):
            if offset >= len(cycled):
                break
            if cycle > 0 and time.monotonic() >= deadline:
                break
            remaining_stages = len(profile.concurrency_ramp) - ramp_index
            stage_count = max(1, (len(cycled) - offset + remaining_stages - 1) // remaining_stages)
            stage = cycled[offset : offset + stage_count]
            offset += len(stage)
            with (
                ThreadPoolExecutor(max_workers=concurrency) as go_executor,
                ThreadPoolExecutor(max_workers=concurrency) as rust_executor,
            ):
                if concurrency not in go.concurrency_levels:
                    go.concurrency_levels.append(concurrency)
                    rust.concurrency_levels.append(concurrency)
                future_targets = {}
                for request in stage:
                    future_targets[
                        go_executor.submit(
                            _execute_one,
                            "go",
                            go_url,
                            request,
                            profile,
                            timeout_seconds,
                        )
                    ] = go
                    future_targets[
                        rust_executor.submit(
                            _execute_one,
                            "rust",
                            rust_url,
                            request,
                            profile,
                            timeout_seconds,
                        )
                    ] = rust
                for future in as_completed(future_targets):
                    future_targets[future].observations.append(future.result())
        cycle += 1

    load_elapsed = time.monotonic() - load_started
    elapsed = time.monotonic() - started
    go.elapsed_seconds = elapsed
    rust.elapsed_seconds = elapsed
    go.load_elapsed_seconds = load_elapsed
    rust.load_elapsed_seconds = load_elapsed
    go.cycles = cycle
    rust.cycles = cycle
    go.observations.sort(key=lambda item: item.index)
    rust.observations.sort(key=lambda item: item.index)
    return go, rust, skipped


def _cycle_requests(
    requests: tuple[TraceRequest, ...],
    cycle: int,
    next_index: int,
) -> tuple[tuple[TraceRequest, ...], int]:
    cycled: list[TraceRequest] = []
    for request in requests:
        headers = dict(request.headers)
        if "idempotency-key" in headers:
            headers["idempotency-key"] = f"{headers['idempotency-key']}-cycle-{cycle:06d}"
        cycled.append(
            replace(
                request,
                index=next_index,
                scenario=f"load_{cycle:06d}_{request.scenario.removeprefix('load_')}",
                headers=headers,
            )
        )
        next_index += 1
    return tuple(cycled), next_index


def _execute_one(
    implementation: str,
    base_url: str,
    request: TraceRequest,
    profile: Profile,
    timeout_seconds: float,
) -> Observation:
    slow = _is_slow_consumer(profile, request.index)
    wire = urllib.request.Request(
        base_url.rstrip("/") + request.path,
        data=request.body,
        method=request.method,
        headers=dict(request.headers),
    )
    started = time.monotonic()
    headers_at = started
    first_byte_at = started
    body = bytearray()
    status = 0
    response_headers: dict[str, str] = {}
    error: str | None = None
    try:
        with urllib.request.urlopen(wire, timeout=timeout_seconds) as response:
            status = response.status
            headers_at = time.monotonic()
            response_headers = _semantic_headers(response.headers.items())
            first = response.read(1)
            first_byte_at = time.monotonic()
            body.extend(first)
            while True:
                if slow:
                    time.sleep(profile.slow_consumer_delay_ms / 1000)
                chunk = response.read(64 if slow else 4096)
                if not chunk:
                    break
                body.extend(chunk)
    except urllib.error.HTTPError as http_error:
        status = http_error.code
        headers_at = time.monotonic()
        first_byte_at = headers_at
        response_headers = _semantic_headers(http_error.headers.items())
        body.extend(http_error.read())
    except Exception as exception:
        error = f"{type(exception).__name__}: {exception}"
    finished = time.monotonic()
    stages = {
        "headers": (headers_at - started) * 1000,
        "ttft": (first_byte_at - started) * 1000,
        "body": (finished - first_byte_at) * 1000,
        "total": (finished - started) * 1000,
    }
    stages.update(_server_timing(response_headers.get("x-timing")))
    prediction_error, prediction_source = (None, None)
    if request.path == "/v1/chat/completions" and status == 200:
        prediction_error, prediction_source = _prediction_error(
            response_headers,
            stages,
            request.predicted_ttft_ms,
        )
    return Observation(
        implementation=implementation,
        index=request.index,
        scenario=request.scenario,
        status=status,
        headers=response_headers,
        body=bytes(body),
        error=error,
        stages_ms=stages,
        prediction_error_ms=prediction_error,
        stream=request.stream,
        prediction_source=prediction_source,
        slow_consumer=slow,
        expected_response_model=(
            request.expected_response_models.get(implementation)
            if request.expected_response_models is not None
            else None
        ),
    )


def _control_peer(
    url: str | None,
    request: TraceRequest,
    profile: Profile,
    timeout: float,
    token: str | None,
) -> None:
    if not url:
        raise ValueError(f"scenario {request.scenario} requires a peer control URL")
    payload = json.dumps(
        {
            "directive": request.peer_directive,
            "request_index": request.index,
            "seed": profile.seed,
            "chunk_multiplier": profile.chunk_multiplier,
        },
        sort_keys=True,
        separators=(",", ":"),
    ).encode()
    headers = {"content-type": "application/json"}
    if token:
        headers["authorization"] = f"Bearer {token}"
    control = urllib.request.Request(
        url,
        data=payload,
        method="POST",
        headers=headers,
    )
    with urllib.request.urlopen(control, timeout=timeout) as response:
        if response.status // 100 != 2:
            raise RuntimeError(f"peer control {url} returned {response.status}")
        response.read()


def _wait_peer_recovery(
    control_url: str | None,
    coordinator_url: str,
    expected_sessions: int,
    timeout: float,
) -> None:
    if not control_url:
        raise ValueError("peer recovery requires a control URL")
    parsed = urllib.parse.urlparse(control_url)
    peer_health_url = urllib.parse.urlunparse(
        (parsed.scheme, parsed.netloc, "/health", "", "", "")
    )
    coordinator_health_url = coordinator_url.rstrip("/") + "/health"
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            with urllib.request.urlopen(peer_health_url, timeout=2) as peer_response:
                peer = json.load(peer_response)
            with urllib.request.urlopen(
                coordinator_health_url, timeout=2
            ) as coordinator_response:
                coordinator = json.load(coordinator_response)
            if (
                peer_response.status == 200
                and coordinator_response.status == 200
                and isinstance(peer, dict)
                and isinstance(coordinator, dict)
                and peer.get("connected_sessions") == expected_sessions
                and coordinator.get("providers") == expected_sessions
            ):
                return
        except Exception:
            pass
        time.sleep(0.1)
    raise RuntimeError(
        "peer did not recover all "
        f"{expected_sessions} sessions at {peer_health_url} and {coordinator_health_url}"
    )


def _semantic_headers(headers: Iterable[tuple[str, str]]) -> dict[str, str]:
    selected: dict[str, str] = {}
    for name, value in headers:
        lowered = name.lower()
        if lowered in SEMANTIC_HEADERS or lowered.startswith(SEMANTIC_HEADER_PREFIXES):
            selected[lowered] = value
    return selected


def _server_timing(encoded: str | None) -> dict[str, float]:
    if not encoded:
        return {}
    try:
        values = json.loads(encoded)
    except json.JSONDecodeError:
        return {}
    if not isinstance(values, dict):
        return {}
    result: dict[str, float] = {}
    for name, value in values.items():
        if isinstance(value, bool) or not isinstance(value, (int, float)):
            continue
        stage = name.removesuffix("_us").removesuffix("_ms")
        if name.endswith("_us"):
            result[stage] = float(value) / 1000
        elif name.endswith("_ms"):
            result[stage] = float(value)
    return result


def _prediction_error(
    headers: dict[str, str],
    stages: dict[str, float],
    independent_prediction_ms: float,
) -> tuple[float | None, str | None]:
    raw = headers.get("x-predicted-ttft-ms")
    source = "x-predicted-ttft-ms" if raw is not None else None
    if raw is None:
        timing = headers.get("x-timing")
        if timing:
            try:
                parsed = json.loads(timing)
                raw_value = parsed.get("predicted_ttft_ms") if isinstance(parsed, dict) else None
                raw = str(raw_value) if isinstance(raw_value, (int, float)) else None
                if raw is not None:
                    source = "x-timing.predicted_ttft_ms"
            except json.JSONDecodeError:
                raw = None
    if raw is None:
        return stages["ttft"] - independent_prediction_ms, "trace_oracle"
    try:
        predicted = float(raw)
    except ValueError:
        return None, None
    return stages["ttft"] - predicted, source


def _is_slow_consumer(profile: Profile, index: int) -> bool:
    randomizer = random.Random((profile.seed << 32) ^ index)
    return randomizer.random() < profile.slow_consumer_fraction
