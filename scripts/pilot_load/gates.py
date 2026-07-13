from __future__ import annotations

from .config import Profile
from .metrics import GateFailure


def evaluate_resources(profile: Profile, resources: dict | None) -> list[GateFailure]:
    failures: list[GateFailure] = []
    if not resources:
        if profile.require_resource_counters:
            failures.append(GateFailure("resources.samples", 0, "at least 2"))
        return failures
    if resources.get("samples", 0) < 2:
        failures.append(GateFailure("resources.samples", resources.get("samples", 0), "at least 2"))
    bounds = profile.resource_bounds
    if profile.require_resource_counters:
        for name in ("go-coordinator", "rust-coordinator"):
            if name not in resources.get("processes", {}):
                failures.append(
                    GateFailure(f"{name}.process_counters", "unavailable", "measured")
                )
    for name, process in resources.get("processes", {}).items():
        if not process.get("available"):
            failures.append(GateFailure(f"{name}.process_counters", "unavailable", "available"))
            continue
        if not process.get("alive_end"):
            failures.append(GateFailure(f"{name}.process_alive_end", "exited", "running"))
        for metric, bound_name in (
            ("rss_growth_bytes", "rss_growth_bytes"),
            ("tasks_growth", "tasks_growth"),
            ("fd_growth", "fd_growth"),
        ):
            actual = max(0, process[metric])
            limit = bounds[bound_name]
            if actual > limit:
                failures.append(GateFailure(f"{name}.{metric}", actual, limit))
    for name, database in resources.get("databases", {}).items():
        if profile.require_resource_counters and database.get("source") != "runtime_counter":
            failures.append(
                GateFailure(
                    f"{name}.database_pool.source",
                    database.get("source", "missing"),
                    "runtime_counter",
                )
            )
        utilization = database.get("utilization_peak")
        if utilization is None:
            failures.append(GateFailure(f"{name}.database_pool", "unavailable", "measured"))
        elif utilization > bounds["database_pool_utilization"]:
            failures.append(
                GateFailure(
                    f"{name}.database_pool_utilization",
                    utilization,
                    bounds["database_pool_utilization"],
                )
            )
    for name in ("go", "rust"):
        mailbox = resources.get("mailboxes", {}).get(name)
        if not mailbox or not mailbox.get("available"):
            if profile.require_resource_counters:
                failures.append(GateFailure(f"{name}.mailbox", "unavailable", "measured"))
            continue
        utilization = mailbox.get("utilization_peak")
        if utilization is None:
            failures.append(GateFailure(f"{name}.mailbox_utilization", "missing", "numeric"))
        elif utilization > bounds["mailbox_utilization"]:
            failures.append(
                GateFailure(
                    f"{name}.mailbox_utilization",
                    utilization,
                    bounds["mailbox_utilization"],
                )
            )
    if profile.require_peer_counters:
        expected_protocols = {
            "go": (profile.websocket_sessions, 0),
            "rust": (0, profile.websocket_sessions),
        }
        for name, (expected_v1, expected_v2) in expected_protocols.items():
            sessions = resources.get("sessions", {}).get(name)
            if not sessions or not sessions.get("available"):
                failures.append(
                    GateFailure(f"{name}.coordinator_sessions", "unavailable", "measured")
                )
                continue
            expected = {
                "provider_sessions_end": profile.websocket_sessions,
                "protocol_v1_sessions_end": expected_v1,
                "protocol_v2_sessions_end": expected_v2,
                "untrusted_sessions_end": 0,
                "self_signed_sessions_end": profile.websocket_sessions,
                "hardware_sessions_end": 0,
            }
            for metric, limit in expected.items():
                if sessions.get(metric) != limit:
                    failures.append(
                        GateFailure(
                            f"{name}.coordinator_sessions.{metric}",
                            sessions.get(metric, "missing"),
                            limit,
                        )
                    )
            minimum_sessions = sessions.get("provider_sessions_min")
            if (
                not isinstance(minimum_sessions, (int, float))
                or isinstance(minimum_sessions, bool)
                or minimum_sessions < profile.websocket_sessions - 1
            ):
                failures.append(
                    GateFailure(
                        f"{name}.coordinator_sessions.provider_sessions_min",
                        minimum_sessions if minimum_sessions is not None else "missing",
                        f"at least {profile.websocket_sessions - 1}",
                    )
                )
    return failures


def evaluate_required_scenarios(profile: Profile, skipped: list[str]) -> list[GateFailure]:
    skipped_required = sorted(set(profile.required_scenarios) & set(skipped))
    if not skipped_required:
        return []
    return [
        GateFailure(
            gate="required_scenarios",
            actual=", ".join(skipped_required),
            limit="none skipped",
        )
    ]


def evaluate_load_execution(
    profile: Profile,
    summaries: dict[str, dict],
    peers: dict[str, dict] | None,
) -> list[GateFailure]:
    failures: list[GateFailure] = []
    minimum_requests = profile.request_count + len(profile.required_scenarios)
    for implementation, summary in summaries.items():
        if summary.get("requests", 0) < minimum_requests:
            failures.append(
                GateFailure(
                    f"{implementation}.load.requests",
                    summary.get("requests", 0),
                    f"at least {minimum_requests}",
                )
            )
        if summary.get("concurrency_levels") != list(profile.concurrency_ramp):
            failures.append(
                GateFailure(
                    f"{implementation}.load.concurrency_ramp",
                    str(summary.get("concurrency_levels")),
                    str(list(profile.concurrency_ramp)),
                )
            )
        if summary.get("slow_consumers", 0) == 0 and profile.slow_consumer_fraction > 0:
            failures.append(
                GateFailure(
                    f"{implementation}.load.slow_consumers",
                    summary.get("slow_consumers", 0),
                    "at least 1 measured slow response",
                )
            )
        elapsed = summary.get("load_elapsed_seconds", 0)
        if profile.soak and elapsed < profile.duration_seconds:
            failures.append(
                GateFailure(
                    f"{implementation}.load.soak_seconds",
                    elapsed,
                    f"at least {profile.duration_seconds}",
                )
            )
    if not profile.require_peer_counters:
        return failures
    if not peers:
        return failures + [GateFailure("peers.counters", "missing", "Go and Rust measured")]
    for implementation in ("go", "rust"):
        peer = peers.get(implementation)
        if not isinstance(peer, dict):
            failures.append(
                GateFailure(f"{implementation}.peer.counters", "missing", "measured")
            )
            continue
        connected = peer.get("connected_sessions")
        if connected != profile.websocket_sessions:
            failures.append(
                GateFailure(
                    f"{implementation}.peer.websocket_sessions",
                    connected if connected is not None else "missing",
                    profile.websocket_sessions,
                )
            )
        served = peer.get("served_requests")
        emitted = peer.get("emitted_chunks")
        if not isinstance(served, int) or served < profile.request_count:
            failures.append(
                GateFailure(
                    f"{implementation}.peer.served_requests",
                    served if served is not None else "missing",
                    f"at least {profile.request_count}",
                )
            )
        minimum_chunks = (
            served * (profile.chunk_multiplier + 2)
            if isinstance(served, int)
            else profile.request_count * (profile.chunk_multiplier + 2)
        )
        if not isinstance(emitted, int) or emitted < minimum_chunks:
            failures.append(
                GateFailure(
                    f"{implementation}.peer.emitted_chunks",
                    emitted if emitted is not None else "missing",
                    f"at least {minimum_chunks}",
                )
            )
        for scenario, counter in (
            ("session_replacement", "session_replacements"),
            ("hedge", "hedges"),
            ("sent_unknown", "sent_unknown_disconnects"),
        ):
            if scenario in profile.required_scenarios and peer.get(counter, 0) < 1:
                failures.append(
                    GateFailure(
                        f"{implementation}.peer.{counter}",
                        peer.get(counter, "missing"),
                        "at least 1 measured action",
                    )
                )
    return failures


def evaluate_database_availability(
    profile: Profile,
    snapshots: dict[str, dict] | None,
) -> list[GateFailure]:
    if not profile.require_billing_snapshot:
        return []
    failures: list[GateFailure] = []
    if not snapshots:
        return [GateFailure("database_snapshots", "unavailable", "Go and Rust available")]
    for name in ("go", "rust"):
        snapshot = snapshots.get(name)
        if not snapshot or not snapshot.get("available"):
            failures.append(
                GateFailure(
                    f"{name}.database_snapshot",
                    snapshot.get("errors") if snapshot else "unavailable",
                    "all billing/provenance queries successful",
                )
            )
            continue
        tables = snapshot.get("tables", {})
        required_tables = [
            "balances",
            "ledger",
            "provider_earnings",
            "usage",
            "usage_totals",
            "settlement_provenance",
        ]
        if name == "rust":
            required_tables.extend(("attempt_delivery", "job_provenance"))
        for table in required_tables:
            rows = tables.get(table)
            if not isinstance(rows, list) or not rows:
                failures.append(
                    GateFailure(
                        f"{name}.database.{table}.rows",
                        0,
                        "at least 1",
                    )
                )
    return failures


def evaluate_resource_baseline(
    profile: Profile,
    resources: dict | None,
    baseline: dict | None,
) -> list[GateFailure]:
    if not baseline:
        return [GateFailure("resources.baseline", "missing", "versioned resource baseline")]
    if not resources:
        return [GateFailure("resources.baseline.actual", "missing", "measured resources")]
    if not isinstance(baseline.get("resources"), dict):
        return [GateFailure("resources.baseline", "missing", "versioned resource baseline")]
    baseline_profile = baseline.get("profile")
    if isinstance(baseline_profile, dict) and baseline_profile.get("name") != profile.name:
        return [
            GateFailure(
                "resources.baseline.profile",
                baseline_profile.get("name", "missing"),
                profile.name,
            )
        ]
    expected_resources = baseline["resources"]
    failures: list[GateFailure] = []
    expected_processes = expected_resources.get("processes", {})
    if not isinstance(expected_processes, dict):
        expected_processes = {}
    for process_name, process in resources.get("processes", {}).items():
        expected = expected_processes.get(process_name)
        if not isinstance(expected, dict):
            failures.append(
                GateFailure(
                    f"{process_name}.baseline.resources",
                    "missing",
                    "process resource baseline",
                )
            )
            continue
        if not process.get("available"):
            continue
        for metric in ("rss_peak_bytes", "tasks_peak", "fd_peak"):
            expected_value = expected.get(metric)
            actual_value = process.get(metric)
            if not isinstance(expected_value, (int, float)) or not isinstance(
                actual_value, (int, float)
            ):
                failures.append(
                    GateFailure(
                        f"{process_name}.baseline.{metric}",
                        "missing",
                        "numeric baseline and measurement",
                    )
                )
                continue
            relative_allowance = expected_value * (
                profile.regression_thresholds["resource_percent"] / 100
            )
            load_allowance = (
                float(max(profile.concurrency_ramp)) if metric == "tasks_peak" else 0.0
            )
            maximum = expected_value + max(relative_allowance, load_allowance)
            if actual_value > maximum:
                failures.append(
                    GateFailure(
                        f"{process_name}.baseline.{metric}",
                        actual_value,
                        maximum,
                    )
                )
    for category in ("databases", "mailboxes"):
        expected_category = expected_resources.get(category, {})
        if not isinstance(expected_category, dict):
            expected_category = {}
        for name, measured in resources.get(category, {}).items():
            expected = expected_category.get(name)
            if not isinstance(expected, dict):
                failures.append(
                    GateFailure(
                        f"{name}.baseline.{category}",
                        "missing",
                        "resource utilization baseline",
                    )
                )
                continue
            actual_value = measured.get("utilization_peak")
            expected_value = expected.get("utilization_peak")
            if not isinstance(actual_value, (int, float)) or not isinstance(
                expected_value, (int, float)
            ):
                failures.append(
                    GateFailure(
                        f"{name}.baseline.{category}.utilization_peak",
                        "missing",
                        "numeric baseline and measurement",
                    )
                )
                continue
            capacity_key = "pool_max" if category == "databases" else "capacity"
            expected_capacity = expected.get(capacity_key)
            sampling_allowance = (
                max(profile.concurrency_ramp) / expected_capacity
                if isinstance(expected_capacity, (int, float))
                and expected_capacity > 0
                else 0.0
            )
            relative_allowance = expected_value * (
                profile.regression_thresholds["resource_percent"] / 100
            )
            maximum = min(
                1.0,
                expected_value + max(relative_allowance, sampling_allowance),
            )
            if actual_value > maximum:
                failures.append(
                    GateFailure(
                        f"{name}.baseline.{category}.utilization_peak",
                        actual_value,
                        maximum,
                    )
                )
    return failures
