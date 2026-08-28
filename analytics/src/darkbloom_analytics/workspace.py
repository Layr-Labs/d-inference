from __future__ import annotations

import datetime as dt
import json
import os
import plistlib
import sys
from pathlib import Path

import duckdb


class Workspace:
    """Creates the local layout and generated Rill/launchd artifacts."""

    def __init__(self, root: Path, memory_limit: str):
        self.root = root
        self.memory_limit = memory_limit

    def initialize(self) -> None:
        for relative in (
            ".",
            "events",
            "events/active",
            "events/ready",
            "events/quarantine",
            "parquet",
            "parquet/jobs",
            "parquet/hourly-rollups",
            "state",
            "state/manifests",
            "tmp",
            "rill",
            "launchd",
        ):
            path = self.root / relative
            path.mkdir(parents=True, exist_ok=True, mode=0o700)
            path.chmod(0o700)
        state = self.root / "state/processor-state.json"
        if not state.exists():
            now = dt.datetime.now(dt.UTC)
            current_hour = now.replace(
                minute=0, second=0, microsecond=0)
            self.write_json_atomic(
                state,
                {
                    "schema_version": 1,
                    "updated_at": _iso(now),
                    "hourly_covered_through": _iso(current_hour),
                    "last_success_at": None,
                    "last_error": None,
                },
            )
        self._create_schema_sentinels()
        self._install_rill_project()
        self._install_launchd_template()

    def _install_rill_project(self) -> None:
        source = Path(__file__).with_name("rill")
        destination = self.root / "rill"
        for template in source.rglob("*"):
            if template.is_dir():
                continue
            relative = template.relative_to(source)
            target = destination / relative
            target.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
            rendered = template.read_text().replace("__ANALYTICS_ROOT__", str(self.root))
            target.write_text(rendered)
            target.chmod(0o600)

    def _install_launchd_template(self) -> None:
        path = self.root / "launchd/dev.darkbloom.analytics.plist"
        value = {
            "Label": "dev.darkbloom.analytics",
            "ProgramArguments": [
                sys.executable,
                "-m",
                "darkbloom_analytics.cli",
                "--root",
                str(self.root),
                "run",
            ],
            "RunAtLoad": True,
            "StartInterval": 300,
            "ProcessType": "Background",
            "LowPriorityIO": True,
            "Nice": 10,
            "StandardOutPath": str(self.root / "state/processor.log"),
            "StandardErrorPath": str(self.root / "state/processor.log"),
        }
        temporary = path.with_name(f".{path.name}.{os.getpid()}.tmp")
        with temporary.open("wb") as stream:
            plistlib.dump(value, stream, fmt=plistlib.FMT_XML, sort_keys=True)
        temporary.chmod(0o600)
        os.replace(temporary, path)

    def _create_schema_sentinels(self) -> None:
        schema_json = self.root / "events/ready/_schema.jsonl"
        if not schema_json.exists():
            sentinel = {
                "schema_version": 1,
                "event_id": "schema",
                "event_at": "1970-01-01T00:00:00Z",
                "event_name": "_schema",
                "process_epoch": "schema",
                "job_id": "schema",
                "trace_id": None,
                "serving_mode": "schema",
                "model": None,
                "outcome": "schema",
                "error_class": None,
                "streaming": False,
                "prompt_tokens": 0,
                "completion_tokens": 0,
                "cached_prompt_tokens": 0,
                "queue_ms": None,
                "ttft_ms": None,
                "total_ms": 0.0,
                "decode_tps": None,
                "earned_micro_usd": None,
                "kv_backend": None,
                "mtp_active": None,
            }
            schema_json.write_text(json.dumps(sentinel, separators=(",", ":")) + "\n")
            schema_json.chmod(0o600)

        jobs_schema = self.root / "parquet/jobs/date=1970-01-01/hour=00/_schema.parquet"
        rollups_schema = self.root / "parquet/hourly-rollups/date=1970-01-01/hour=00/_schema.parquet"
        jobs_schema.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        rollups_schema.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        if jobs_schema.exists() and rollups_schema.exists():
            return
        connection = duckdb.connect(":memory:")
        try:
            connection.execute("SET threads = 1")
            connection.execute(f"SET memory_limit = '{_sql_literal(self.memory_limit)}'")
            if not jobs_schema.exists():
                connection.execute(
                    f"""
                    COPY (
                        SELECT
                            1::INTEGER schema_version, ''::VARCHAR event_id,
                            now()::TIMESTAMPTZ event_at, ''::VARCHAR event_name,
                            ''::VARCHAR process_epoch, ''::VARCHAR job_id,
                            NULL::VARCHAR trace_id, ''::VARCHAR serving_mode,
                            NULL::VARCHAR model, ''::VARCHAR outcome,
                            NULL::VARCHAR error_class, false::BOOLEAN streaming,
                            0::BIGINT prompt_tokens, 0::BIGINT completion_tokens,
                            0::BIGINT cached_prompt_tokens, NULL::DOUBLE queue_ms,
                            NULL::DOUBLE ttft_ms, 0::DOUBLE total_ms,
                            NULL::DOUBLE decode_tps, NULL::BIGINT earned_micro_usd,
                            NULL::VARCHAR kv_backend, NULL::BOOLEAN mtp_active
                        WHERE false
                    ) TO '{_sql_literal(str(jobs_schema))}' (FORMAT PARQUET)
                    """
                )
            if not rollups_schema.exists():
                connection.execute(
                    f"""
                    COPY (
                        SELECT now()::TIMESTAMPTZ hour_start, NULL::VARCHAR model,
                            ''::VARCHAR serving_mode, ''::VARCHAR outcome,
                            NULL::VARCHAR kv_backend, NULL::BOOLEAN mtp_active,
                            0::BIGINT jobs, 0::HUGEINT prompt_tokens,
                            0::HUGEINT completion_tokens, 0::HUGEINT cached_prompt_tokens,
                            0::HUGEINT earned_micro_usd, 0::BIGINT errors,
                            0::BIGINT cancellations, 0::DOUBLE ttft_sum_ms,
                            0::DOUBLE total_duration_sum_ms
                        WHERE false
                    ) TO '{_sql_literal(str(rollups_schema))}' (FORMAT PARQUET)
                    """
                )
        finally:
            connection.close()
        jobs_schema.chmod(0o600)
        rollups_schema.chmod(0o600)

    @staticmethod
    def write_json_atomic(path: Path, value: dict) -> None:
        temporary = path.with_name(f".{path.name}.{os.getpid()}.tmp")
        temporary.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")
        temporary.chmod(0o600)
        os.replace(temporary, path)


def _iso(value: dt.datetime) -> str:
    return value.astimezone(dt.UTC).isoformat(timespec="seconds").replace("+00:00", "Z")


def _sql_literal(value: str) -> str:
    return value.replace("'", "''")
