"""Milestones are observations on one network path, not proof of internal bind time."""
from collections import Counter
from dataclasses import dataclass
from datetime import datetime, timezone
import time

from .http_probe import Client


class Clock:
    monotonic = staticmethod(time.monotonic)
    sleep = staticmethod(time.sleep)

    @staticmethod
    def now():
        return datetime.now(timezone.utc)


@dataclass
class Settings:
    base_url: str
    expected_build: str
    models: list[str]
    process_started_at: datetime
    old_process_stopped_at: datetime | None = None
    duration: float = 180
    interval: float = 0.5
    request_timeout: float = 2


def capacity_snapshot(result, models):
    body = result.body if isinstance(result.body, dict) else {}
    rows = body.get("models")
    candidates = {}
    if result.status == 200 and body.get("draining", False) is False and isinstance(rows, list):
        for row in rows:
            if isinstance(row, dict) and row.get("id") in models:
                candidates.setdefault(row["id"], []).append(row)
    output = {}
    for model in models:
        matches = candidates.get(model, [])
        row = matches[0] if len(matches) == 1 else {}
        count = row.get("routable_providers")
        count = count if type(count) is int and count >= 0 else 0
        output[model] = {"routable_providers": count,
                         "eligible": row.get("ready") is True and row.get("can_accept") is True and count > 0}
    return output


class Observer:
    def __init__(self, settings, *, client=None, probe=None, clock=None):
        self.settings = settings
        self.client = client or Client(settings.base_url)
        self.probe = probe
        self.clock = clock or Clock()
        self.milestones = {}
        self.last_unsatisfied = {}
        self.status_counts = Counter()
        self.samples = []
        self.probes = []

    def timestamp(self):
        now = self.clock.now()
        result = {"at": now.isoformat(), "process_start_ms": round((now - self.settings.process_started_at).total_seconds() * 1000, 3)}
        if self.settings.old_process_stopped_at is not None:
            result["old_stop_ms"] = round((now - self.settings.old_process_stopped_at).total_seconds() * 1000, 3)
        return result

    def observe(self, name, satisfied):
        stamp = self.timestamp()
        if satisfied and name not in self.milestones:
            self.milestones[name] = {"first_satisfied": stamp,
                                     "last_unsatisfied": self.last_unsatisfied.get(name),
                                     "left_censored": name not in self.last_unsatisfied}
        elif not satisfied and name not in self.milestones:
            self.last_unsatisfied[name] = stamp

    def read(self, path, deadline):
        remaining = deadline - self.clock.monotonic()
        if remaining <= 0:
            return None
        started = self.timestamp()
        began = self.clock.monotonic()
        result = self.client.request(path, min(self.settings.request_timeout, remaining))
        result.observation = {"started": started, "finished": self.timestamp(),
                              "duration_ms": round((self.clock.monotonic() - began) * 1000, 3)}
        self.status_counts[f"{path}:{result.status if result.status is not None else result.outcome}"] += 1
        return result

    def run(self):
        began = self.timestamp()
        deadline = self.clock.monotonic() + self.settings.duration
        attempts = Counter()
        next_probe_at = 0
        reached = False
        current = {}
        while self.clock.monotonic() < deadline:
            health = self.read("/health", deadline)
            if health is None:
                break
            self.observe("http_response", health.status is not None)
            body = health.body if isinstance(health.body, dict) else {}
            candidate = health.status == 200 and body.get("status") == "ok" and body.get("build_commit") == self.settings.expected_build
            self.observe("candidate_health", candidate)
            sample = {**self.timestamp(), "health": health.public(), "candidate_matches": candidate}
            ready = False
            current = {model: {"routable_providers": 0, "eligible": False} for model in self.settings.models}
            if candidate:
                readiness = self.read("/readyz", deadline)
                if readiness is not None:
                    data = readiness.body if isinstance(readiness.body, dict) else {}
                    ready = readiness.status == 200 and data.get("ready") is True and data.get("draining") is False
                    sample["readiness"] = readiness.public()
                self.observe("ready", ready)
                capacity = self.read("/v1/models/capacity", deadline) if ready else None
                if capacity is not None:
                    current = capacity_snapshot(capacity, self.settings.models)
                    sample["capacity"] = capacity.public()
            else:
                self.observe("ready", False)
            for model, state in current.items():
                self.observe("capacity:" + model, candidate and ready and state["eligible"])
            all_ready = candidate and ready and all(state["eligible"] for state in current.values())
            self.observe("all_models_capacity", all_ready)
            sample["models"] = current
            sample["finished"] = self.timestamp()
            self.samples.append(sample)
            if self.probe and candidate and ready and self.clock.monotonic() >= next_probe_at:
                for model, state in current.items():
                    if not state["eligible"] or "inference:" + model in self.milestones or attempts[model] >= self.probe.max_attempts:
                        continue
                    remaining = deadline - self.clock.monotonic()
                    if remaining <= 0:
                        break
                    attempts[model] += 1
                    probe_started = self.timestamp()
                    result = self.probe.run(self.client, model, min(10, remaining))
                    self.probes.append({**self.timestamp(), "started": probe_started,
                                        "since_model_first_capacity_ms": probe_started["process_start_ms"] - self.milestones["capacity:" + model]["first_satisfied"]["process_start_ms"],
                                        "model": model, "attempt": attempts[model], **result})
                    self.observe("first_inference", result["availability_success"])
                    self.observe("inference:" + model, result["availability_success"])
                    next_probe_at = self.clock.monotonic() + 1
                    break  # at most one synthetic request per second across models
            completed = (not self.probe or all("inference:" + model in self.milestones for model in self.settings.models))
            if all_ready and completed and self.clock.monotonic() <= deadline:
                reached = True
                break
            self.clock.sleep(min(self.settings.interval, max(0, deadline - self.clock.monotonic())))
        correctness = "not_measured"
        if self.probe:
            matches = {item["model"]: item["synthetic_answer_matches"] for item in self.probes if item["availability_success"]}
            correctness = "failed" if False in matches.values() else ("passed" if len(matches) == len(self.settings.models) else "incomplete")
        return {"schema_version": 1, "mode": "disposable_test_inference" if self.probe else "read_only",
                "target_origin": self.settings.base_url, "expected_build_commit": self.settings.expected_build,
                "process_started_at": self.settings.process_started_at.isoformat(),
                "old_process_stopped_at": self.settings.old_process_stopped_at.isoformat() if self.settings.old_process_stopped_at else None,
                "observer_started": began, "finished": self.timestamp(),
                "measurement_target_reached": reached, "inference_verified": bool(self.probe) and all("inference:" + model in self.milestones for model in self.settings.models),
                "correctness": correctness,
                "milestones": self.milestones, "http_status_counts": dict(self.status_counts), "samples": self.samples,
                "inference_probes": self.probes,
                "limits": {"observation_window_seconds": self.settings.duration,
                           "poll_interval_seconds": self.settings.interval, "request_timeout_seconds": self.settings.request_timeout,
                           "capacity_endpoint_cache_seconds": 2,
                           "correctness_scope": "exact synthetic reply only, not model qualification",
                           "serving_not_proven_by_health_or_capacity": True,
                           "listener_bind_time_not_directly_measured": True,
                           "external_clock_alignment_not_verified": True,
                           "drain_not_included": True}}
