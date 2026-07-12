from __future__ import annotations

import json
import re
from typing import Any


GO_LOAD_TESTS = frozenset(
    {
        "TestLoad_SingleProviderBurst",
        "TestLoad_SingleProviderConcurrent",
        "TestLoad_MultiProviderLoadBalance",
        "TestLoad_ProviderFailureMidLoad",
        "TestLoad_ConcurrentBillingUnderLoad",
        "TestLoad_RaceSafety",
        "TestHandleChunkOverflowGraceDeliversToSlowConsumer",
    }
)
RUST_COMPONENT_TESTS = {
    "rust-1000-ws": (
        "http::tests::one_thousand_concurrent_real_websocket_sessions_remain_bounded"
    ),
    "rust-10x-requests": (
        "http::tests::one_provider_serves_over_one_thousand_sequential_requests_without_writer_debit_leak"
    ),
    "rust-concurrency-slow-consumers": (
        "http::tests::concurrent_http_requests_receive_interleaved_websocket_chunks_with_bounded_resources"
    ),
    "rust-session-replacement": (
        "http::tests::replacement_replay_ack_historical_terminal_and_v2_to_v1_are_fenced"
    ),
    "rust-hedge": "request::task::tests::one_job_bounds_hedge_and_preserves_fast_start_output_order",
    "rust-sent-unknown": (
        "provider::writer::tests::send_timeout_is_sent_unknown_and_fences_followers"
    ),
}


def expected_component_tests(name: str) -> frozenset[str]:
    if name == "go-load":
        return GO_LOAD_TESTS
    rust_test = RUST_COMPONENT_TESTS.get(name)
    return frozenset({rust_test}) if rust_test else frozenset()


def measured_component_tests(name: str, output: str) -> frozenset[str]:
    if name == "go-load":
        passed: set[str] = set()
        for line in output.splitlines():
            try:
                event = json.loads(line)
            except json.JSONDecodeError:
                continue
            if (
                isinstance(event, dict)
                and event.get("Action") == "pass"
                and isinstance(event.get("Test"), str)
            ):
                passed.add(event["Test"])
        return frozenset(passed)
    if name in RUST_COMPONENT_TESTS:
        return frozenset(
            match.group(1)
            for match in re.finditer(r"^test (\S+) \.\.\. ok$", output, re.MULTILINE)
        )
    return frozenset()


def component_coverage(results: list[dict[str, Any]]) -> dict[str, bool]:
    passed_tests: set[str] = set()
    for result in results:
        measured = result.get("passed_tests")
        if (
            result.get("exit_code") != 0
            or result.get("measurement_complete") is not True
            or not isinstance(measured, list)
        ):
            continue
        passed_tests.update(test for test in measured if isinstance(test, str))
    return {
        "go_in_process_coordinator": GO_LOAD_TESTS.issubset(passed_tests),
        "rust_in_process_coordinator": RUST_COMPONENT_TESTS["rust-1000-ws"] in passed_tests,
        "synthetic_go_peer": GO_LOAD_TESTS.issubset(passed_tests),
        "synthetic_rust_v2_peer": RUST_COMPONENT_TESTS["rust-1000-ws"] in passed_tests,
        "slow_consumers": {
            "TestHandleChunkOverflowGraceDeliversToSlowConsumer",
            RUST_COMPONENT_TESTS["rust-concurrency-slow-consumers"],
        }.issubset(passed_tests),
        "session_replacement": RUST_COMPONENT_TESTS["rust-session-replacement"] in passed_tests,
        "hedge": RUST_COMPONENT_TESTS["rust-hedge"] in passed_tests,
        "sent_unknown": RUST_COMPONENT_TESTS["rust-sent-unknown"] in passed_tests,
    }
