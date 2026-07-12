from __future__ import annotations

import json
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from .client import Observation, TargetRun
from .metrics import GateFailure
from .trace import TraceRequest


@dataclass(frozen=True)
class ContractOracle:
    version: int
    contracts: dict[str, dict[str, Any]]


def load_oracle(path: Path) -> ContractOracle:
    with path.open(encoding="utf-8") as handle:
        document = json.load(handle)
    if not isinstance(document, dict) or document.get("schema_version") != 1:
        raise ValueError(f"{path} must be a schema_version 1 contract oracle")
    version = document.get("oracle_version")
    contracts = document.get("contracts")
    if isinstance(version, bool) or not isinstance(version, int) or version <= 0:
        raise ValueError("contract oracle requires a positive oracle_version")
    if not isinstance(contracts, dict) or not contracts:
        raise ValueError("contract oracle requires a nonempty contracts object")
    for scenario, rule in contracts.items():
        if not isinstance(scenario, str) or not scenario or not isinstance(rule, dict):
            raise ValueError("contract oracle scenarios must map to objects")
        _validate_rule(scenario, rule)
        overrides = rule.get("implementation_overrides", {})
        if not isinstance(overrides, dict) or any(
            implementation not in {"go", "rust"} or not isinstance(override, dict)
            for implementation, override in overrides.items()
        ):
            raise ValueError(f"oracle scenario {scenario!r} has invalid implementation overrides")
        for implementation, override in overrides.items():
            merged = {key: value for key, value in rule.items() if key != "implementation_overrides"}
            merged.update(override)
            _validate_rule(f"{scenario}.{implementation}", merged)
    return ContractOracle(version=version, contracts=contracts)


def evaluate_oracle(
    oracle: ContractOracle,
    trace: tuple[TraceRequest, ...],
    runs: dict[str, TargetRun],
) -> list[GateFailure]:
    requests = {request.index: request for request in trace}
    failures: list[GateFailure] = []
    for implementation, run in runs.items():
        observations = {observation.index: observation for observation in run.observations}
        for index, request in requests.items():
            observation = observations.get(index)
            if observation is None:
                failures.append(
                    GateFailure(
                        f"{implementation}.oracle.{request.scenario}.observation",
                        "missing",
                        "measured",
                    )
                )
                continue
            failures.extend(_evaluate_one(oracle, request, observation))
        for index in sorted(set(observations) - set(requests)):
            observation = observations[index]
            failures.extend(
                _evaluate_one(
                    oracle,
                    TraceRequest(
                        index=index,
                        scenario=observation.scenario,
                        method="POST",
                        path="/v1/chat/completions",
                        headers={},
                        body=b"{}",
                        stream=observation.stream,
                    ),
                    observation,
                )
            )
    return failures


def _evaluate_one(
    oracle: ContractOracle,
    request: TraceRequest,
    observation: Observation,
) -> list[GateFailure]:
    implementation = observation.implementation
    scenario = _contract_scenario(request)
    rule = oracle.contracts.get(scenario)
    prefix = f"{implementation}.oracle.{request.scenario}"
    if rule is None:
        return [GateFailure(f"{prefix}.contract", "missing", scenario)]
    override = rule.get("implementation_overrides", {}).get(implementation, {})
    if override:
        rule = {
            **{key: value for key, value in rule.items() if key != "implementation_overrides"},
            **override,
        }
    failures: list[GateFailure] = []
    if observation.error is not None:
        failures.append(GateFailure(f"{prefix}.transport", observation.error, "none"))
    statuses = rule["statuses"]
    if observation.status not in statuses:
        failures.append(
            GateFailure(
                f"{prefix}.status",
                observation.status,
                "|".join(str(value) for value in statuses),
            )
        )
    if not observation.body:
        failures.append(GateFailure(f"{prefix}.body", "empty", "nonempty measured body"))
        return failures
    for name, pattern in rule.get("headers", {}).items():
        actual = observation.headers.get(name.lower())
        if actual is None:
            failures.append(GateFailure(f"{prefix}.header.{name}", "missing", pattern))
        elif re.search(pattern, actual, flags=re.IGNORECASE) is None:
            failures.append(GateFailure(f"{prefix}.header.{name}", actual, pattern))
    expected_model = None
    if request.expected_response_models is not None:
        expected_model = request.expected_response_models.get(implementation)
    if expected_model is None:
        expected_model = observation.expected_response_model
    failures.extend(
        _evaluate_body(
            prefix,
            rule["body"],
            observation.body,
            expected_response_model=expected_model,
        )
    )
    return failures


def _validate_rule(scenario: str, rule: dict[str, Any]) -> None:
    statuses = rule.get("statuses")
    if (
        not isinstance(statuses, list)
        or not statuses
        or any(isinstance(value, bool) or not isinstance(value, int) for value in statuses)
    ):
        raise ValueError(f"oracle scenario {scenario!r} requires integer statuses")
    headers = rule.get("headers", {})
    if not isinstance(headers, dict) or any(
        not isinstance(name, str) or not isinstance(pattern, str)
        for name, pattern in headers.items()
    ):
        raise ValueError(f"oracle scenario {scenario!r} has invalid headers")
    body = rule.get("body")
    if not isinstance(body, dict):
        raise ValueError(f"oracle scenario {scenario!r} requires a body contract")
    if body.get("kind") not in {"json", "sse", "text"}:
        raise ValueError(f"oracle scenario {scenario!r} has an invalid body kind")
    if body.get("response_model") not in {None, "trace_expected"}:
        raise ValueError(f"oracle scenario {scenario!r} has an invalid response model contract")


def _evaluate_body(
    prefix: str,
    contract: dict[str, Any],
    body: bytes,
    *,
    expected_response_model: str | None,
) -> list[GateFailure]:
    kind = contract.get("kind")
    if kind == "sse":
        return _evaluate_sse(
            prefix,
            contract,
            body,
            expected_response_model=expected_response_model,
        )
    if kind == "text":
        text = body.decode("utf-8", errors="replace")
        pattern = contract.get("matches")
        if not isinstance(pattern, str) or re.search(pattern, text, re.IGNORECASE) is None:
            return [GateFailure(f"{prefix}.body_text", text[:200], str(pattern))]
        return []
    if kind != "json":
        return [GateFailure(f"{prefix}.body_contract", str(kind), "json|sse|text")]
    try:
        value = json.loads(body)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        return [GateFailure(f"{prefix}.body_json", str(error), "valid JSON")]
    failures: list[GateFailure] = []
    for pointer in contract.get("required", []):
        actual = _resolve_pointer(value, pointer)
        if actual is _MISSING:
            failures.append(GateFailure(f"{prefix}.body{pointer}", "missing", "present"))
    for pointer, expected in contract.get("equals", {}).items():
        actual = _resolve_pointer(value, pointer)
        if actual != expected:
            failures.append(
                GateFailure(
                    f"{prefix}.body{pointer}",
                    "<missing>" if actual is _MISSING else json.dumps(actual, sort_keys=True),
                    json.dumps(expected, sort_keys=True),
                )
            )
    if contract.get("response_model") == "trace_expected":
        actual = _resolve_pointer(value, "/model")
        if expected_response_model is None:
            failures.append(
                GateFailure(f"{prefix}.body/model.contract", "missing", "trace expectation")
            )
        elif actual != expected_response_model:
            failures.append(
                GateFailure(
                    f"{prefix}.body/model",
                    "<missing>" if actual is _MISSING else json.dumps(actual),
                    json.dumps(expected_response_model),
                )
            )
    return failures


def _evaluate_sse(
    prefix: str,
    contract: dict[str, Any],
    body: bytes,
    *,
    expected_response_model: str | None,
) -> list[GateFailure]:
    text = body.decode("utf-8", errors="replace").replace("\r\n", "\n")
    blocks = [block for block in text.split("\n\n") if block.strip()]
    data = [
        "\n".join(
            line.partition(":")[2].lstrip()
            for line in block.splitlines()
            if line.startswith("data:")
        )
        for block in blocks
    ]
    data = [value for value in data if value]
    failures: list[GateFailure] = []
    minimum = contract.get("minimum_events", 1)
    if len(data) < minimum:
        failures.append(GateFailure(f"{prefix}.sse.events", len(data), minimum))
    if contract.get("done") and "[DONE]" not in data:
        failures.append(GateFailure(f"{prefix}.sse.done", "missing", "[DONE]"))
    content_pattern = contract.get("content_matches")
    if isinstance(content_pattern, str) and re.search(content_pattern, text) is None:
        failures.append(GateFailure(f"{prefix}.sse.content", "missing", content_pattern))
    response_models: list[Any] = []
    for payload in data:
        if payload == "[DONE]":
            continue
        try:
            decoded = json.loads(payload)
        except json.JSONDecodeError as error:
            failures.append(GateFailure(f"{prefix}.sse.json", str(error), "valid JSON data"))
            break
        if isinstance(decoded, dict) and "model" in decoded:
            response_models.append(decoded["model"])
    if contract.get("response_model") == "trace_expected":
        if expected_response_model is None:
            failures.append(
                GateFailure(f"{prefix}.sse.model.contract", "missing", "trace expectation")
            )
        elif not response_models:
            failures.append(GateFailure(f"{prefix}.sse.model", "missing", expected_response_model))
        elif any(model != expected_response_model for model in response_models):
            failures.append(
                GateFailure(
                    f"{prefix}.sse.model",
                    json.dumps(response_models[:10], sort_keys=True),
                    json.dumps(expected_response_model),
                )
            )
    return failures


def _contract_scenario(request: TraceRequest) -> str:
    if request.scenario.startswith("load_"):
        return "load_stream" if request.stream else "load_nonstream"
    return request.scenario


_MISSING = object()


def _resolve_pointer(value: Any, pointer: str) -> Any:
    if pointer == "":
        return value
    if not isinstance(pointer, str) or not pointer.startswith("/"):
        return _MISSING
    current = value
    for encoded in pointer[1:].split("/"):
        segment = encoded.replace("~1", "/").replace("~0", "~")
        if isinstance(current, dict) and segment in current:
            current = current[segment]
        elif isinstance(current, list) and segment.isdigit() and int(segment) < len(current):
            current = current[int(segment)]
        else:
            return _MISSING
    return current
