#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

python3 "$ROOT/deploy/datadog/validate-rust-observability.py"
bash -n \
  "$ROOT/deploy/gcp/refresh-env.sh" \
  "$ROOT/deploy/gcp/run-coordinator.sh" \
  "$ROOT/deploy/gcp/run-recovery.sh" \
  "$ROOT/deploy/gcp/vm-startup.sh"

python3 - "$ROOT" <<'PY'
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
refresh = (root / "deploy/gcp/refresh-env.sh").read_text(encoding="utf-8")
dockerfile = (root / "coordinator/Dockerfile").read_text(encoding="utf-8")
coordinator = (
    root / "deploy/gcp/systemd/d-inference-coordinator.service"
).read_text(encoding="utf-8")
recovery = (
    root / "deploy/gcp/systemd/d-inference-recovery.service"
).read_text(encoding="utf-8")
startup = (root / "deploy/gcp/vm-startup.sh").read_text(encoding="utf-8")
datadog = (
    root / "coordinator-rs/crates/server/src/telemetry/datadog.rs"
).read_text(encoding="utf-8")
periodic = (
    root / "coordinator-rs/crates/server/src/telemetry/periodic.rs"
).read_text(encoding="utf-8")
cloudbuilds = [
    (root / "deploy/gcp/cloudbuild.yaml").read_text(encoding="utf-8"),
    (root / "deploy/gcp/cloudbuild-prod.yaml").read_text(encoding="utf-8"),
]

required_env = [
    "DD_ENV=${DD_ENVIRONMENT}",
    "DD_SERVICE=d-inference-coordinator",
    "DD_AGENT_HOST=127.0.0.1",
    "DD_DOGSTATSD_ENABLED=true",
    "DD_TRACE_ENABLED=true",
]
for value in required_env:
    if value not in refresh:
        raise SystemExit(f"missing Datadog runtime setting: {value}")

for value in [
    "ENV DD_VERSION=${BUILD_VERSION}",
    "ENV DD_GIT_COMMIT_SHA=${BUILD_COMMIT}",
    'org.opencontainers.image.revision="${BUILD_COMMIT}"',
]:
    if value not in dockerfile:
        raise SystemExit(f"missing immutable image telemetry tag: {value}")

for cloudbuild in cloudbuilds:
    if '--build-arg="BUILD_DATE=$(date -u +%Y-%m-%dT%H:%M:%SZ)"' not in cloudbuild:
        raise SystemExit("Cloud Build does not inject immutable build date metadata")

for name, unit in [("coordinator", coordinator), ("recovery", recovery)]:
    for value in ["StandardOutput=journal", "StandardError=journal", "SyslogIdentifier="]:
        if value not in unit:
            raise SystemExit(f"{name} unit is missing structured journald setting: {value}")

for value in [
    "Environment=DD_LOGS_ENABLED=true",
    "Environment=DD_APM_ENABLED=true",
    "Environment=DD_APM_RECEIVER_PORT=8126",
    "Environment=DD_DOGSTATSD_PORT=8125",
    "histogram_aggregates:",
    "histogram_percentiles:",
    "  - 0.95",
    "  - 0.99",
    "env:${DD_ENV_VALUE:-$ENVIRONMENT}",
    "systemctl restart datadog-agent.service",
]:
    if value not in startup:
        raise SystemExit(f"host Agent wiring is missing: {value}")

if 'MetricKind::Histogram => "h"' not in datadog:
    raise SystemExit("Rust latency samples are not emitted as DogStatsD histograms")
if "Duration::from_secs(15)" not in periodic:
    raise SystemExit("periodic gauges do not enforce the 15-second freshness bound")

print("rust observability shell wiring passed")
PY
