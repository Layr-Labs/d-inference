from __future__ import annotations

import datetime as dt
import json
import os
import shutil
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable

import duckdb

from .schema import ValidatedEvent, ValidationError, validate_event
from .workspace import Workspace


@dataclass(frozen=True)
class ProcessorConfig:
    root: Path
    completion_grace: dt.timedelta = dt.timedelta(minutes=5)
    raw_retention: dt.timedelta = dt.timedelta(days=3)
    jobs_retention: dt.timedelta = dt.timedelta(days=90)
    memory_limit: str = "256MB"


@dataclass(frozen=True)
class RunResult:
    processed_hours: tuple[str, ...]
    quarantined_files: tuple[str, ...]


class Processor:
    def __init__(self, config: ProcessorConfig):
        self.config = config
        self.root = config.root.expanduser().resolve()
        self.workspace = Workspace(self.root, config.memory_limit)

    def initialize(self) -> None:
        self.workspace.initialize()

    def run(self, *, now: dt.datetime | None = None) -> RunResult:
        self.initialize()
        try:
            return self._run_initialized(now=now)
        except Exception as exc:
            self._record_error(exc)
            raise

    def _run_initialized(self, *, now: dt.datetime | None = None) -> RunResult:
        now = (now or dt.datetime.now(dt.UTC)).astimezone(dt.UTC)
        cutoff = now - self.config.completion_grace
        records_by_hour: dict[dt.datetime, list[tuple[Path, ValidatedEvent]]] = {}
        quarantined: list[str] = []

        for path in sorted((self.root / "events/ready").glob("**/*.jsonl")):
            if path.name.startswith("_"):
                continue
            try:
                records = list(self._read_segment(path))
            except (OSError, json.JSONDecodeError, ValidationError) as exc:
                quarantined.append(str(self._quarantine(path, exc)))
                continue
            for record in records:
                records_by_hour.setdefault(record.hour, []).append((path, record))

        processed: list[str] = []
        for hour in sorted(records_by_hour):
            if hour + dt.timedelta(hours=1) > cutoff:
                continue
            self._process_hour(hour, records_by_hour[hour])
            processed.append(_hour_key(hour))

        self._advance_coverage(
            records_by_hour,
            cutoff,
            now,
            allow_advance=not quarantined,
        )
        self._apply_retention(now)
        return RunResult(tuple(processed), tuple(quarantined))

    def status(self) -> dict:
        self.initialize()
        return json.loads((self.root / "state/processor-state.json").read_text())

    def _read_segment(self, path: Path) -> Iterable[ValidatedEvent]:
        seen: set[str] = set()
        with path.open("r", encoding="utf-8") as stream:
            for number, line in enumerate(stream, start=1):
                if not line.endswith("\n"):
                    raise ValidationError(f"line {number} is not newline-terminated")
                value = json.loads(line)
                event = validate_event(value)
                event_id = event.value["event_id"]
                if event_id in seen:
                    raise ValidationError(f"duplicate event_id on line {number}")
                seen.add(event_id)
                yield event

    def _process_hour(
        self,
        hour: dt.datetime,
        records: list[tuple[Path, ValidatedEvent]],
    ) -> None:
        event_ids: set[str] = set()
        for _, event in records:
            if event.value["event_id"] in event_ids:
                raise ValidationError(f"duplicate event_id in hour {_hour_key(hour)}")
            event_ids.add(event.value["event_id"])

        day = hour.strftime("%Y-%m-%d")
        hour_number = hour.strftime("%H")
        jobs_dir = self.root / f"parquet/jobs/date={day}/hour={hour_number}"
        rollups_dir = self.root / f"parquet/hourly-rollups/date={day}/hour={hour_number}"
        jobs_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
        rollups_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
        input_files = sorted({str(path.relative_to(self.root)) for path, _ in records})
        manifest_path = self.root / f"state/manifests/{hour.strftime('%Y%m%dT%H0000Z')}.json"
        if manifest_path.exists() and (jobs_dir / "jobs.parquet").exists() and (rollups_dir / "rollup.parquet").exists():
            existing = json.loads(manifest_path.read_text())
            if existing.get("input_files") == input_files and existing.get("input_records") == len(records):
                return
        token = f"{hour.strftime('%Y%m%dT%H%M%SZ')}-{os.getpid()}"
        normalized = self.root / f"tmp/{token}.jsonl"
        jobs_temp = self.root / f"tmp/{token}-jobs.parquet"
        rollup_temp = self.root / f"tmp/{token}-rollup.parquet"

        with normalized.open("w", encoding="utf-8") as stream:
            for _, event in sorted(records, key=lambda item: item[1].event_at):
                json.dump(event.value, stream, separators=(",", ":"), sort_keys=True)
                stream.write("\n")
        normalized.chmod(0o600)

        connection = duckdb.connect(":memory:")
        try:
            connection.execute("SET threads = 1")
            connection.execute(f"SET memory_limit = '{_sql_literal(self.config.memory_limit)}'")
            connection.execute("SET preserve_insertion_order = false")
            connection.execute(f"SET temp_directory = '{_sql_literal(str(self.root / 'tmp'))}'")
            connection.execute(
                f"""
                CREATE TABLE jobs AS
                SELECT
                    schema_version::INTEGER AS schema_version,
                    event_id::VARCHAR AS event_id,
                    event_at::TIMESTAMPTZ AS event_at,
                    event_name::VARCHAR AS event_name,
                    process_epoch::VARCHAR AS process_epoch,
                    job_id::VARCHAR AS job_id,
                    trace_id::VARCHAR AS trace_id,
                    serving_mode::VARCHAR AS serving_mode,
                    model::VARCHAR AS model,
                    outcome::VARCHAR AS outcome,
                    error_class::VARCHAR AS error_class,
                    streaming::BOOLEAN AS streaming,
                    prompt_tokens::BIGINT AS prompt_tokens,
                    completion_tokens::BIGINT AS completion_tokens,
                    cached_prompt_tokens::BIGINT AS cached_prompt_tokens,
                    queue_ms::DOUBLE AS queue_ms,
                    ttft_ms::DOUBLE AS ttft_ms,
                    total_ms::DOUBLE AS total_ms,
                    decode_tps::DOUBLE AS decode_tps,
                    earned_micro_usd::BIGINT AS earned_micro_usd,
                    kv_backend::VARCHAR AS kv_backend,
                    mtp_active::BOOLEAN AS mtp_active
                FROM read_json_auto('{_sql_literal(str(normalized))}', maximum_object_size=1048576)
                """
            )
            count, distinct_count = connection.execute(
                "SELECT count(*), count(DISTINCT event_id) FROM jobs"
            ).fetchone()
            if count != len(records) or distinct_count != count:
                raise ValidationError("DuckDB row-count or event-id validation failed")
            connection.execute(
                f"COPY jobs TO '{_sql_literal(str(jobs_temp))}' "
                "(FORMAT PARQUET, COMPRESSION ZSTD)"
            )
            connection.execute(
                f"""
                COPY (
                    SELECT
                        date_trunc('hour', event_at) AS hour_start,
                        model,
                        serving_mode,
                        outcome,
                        kv_backend,
                        mtp_active,
                        count(*)::BIGINT AS jobs,
                        sum(prompt_tokens)::HUGEINT AS prompt_tokens,
                        sum(completion_tokens)::HUGEINT AS completion_tokens,
                        sum(cached_prompt_tokens)::HUGEINT AS cached_prompt_tokens,
                        sum(coalesce(earned_micro_usd, 0))::HUGEINT AS earned_micro_usd,
                        count(*) FILTER (WHERE outcome = 'failed')::BIGINT AS errors,
                        count(*) FILTER (WHERE outcome = 'cancelled')::BIGINT AS cancellations,
                        sum(coalesce(ttft_ms, 0))::DOUBLE AS ttft_sum_ms,
                        sum(total_ms)::DOUBLE AS total_duration_sum_ms
                    FROM jobs
                    GROUP BY ALL
                ) TO '{_sql_literal(str(rollup_temp))}'
                (FORMAT PARQUET, COMPRESSION ZSTD)
                """
            )
            rollup_count = connection.execute(
                "SELECT count(*) FROM read_parquet(?)", [str(rollup_temp)]
            ).fetchone()[0]
        except Exception:
            jobs_temp.unlink(missing_ok=True)
            rollup_temp.unlink(missing_ok=True)
            raise
        finally:
            connection.close()
            normalized.unlink(missing_ok=True)

        os.replace(jobs_temp, jobs_dir / "jobs.parquet")
        os.replace(rollup_temp, rollups_dir / "rollup.parquet")
        (jobs_dir / "jobs.parquet").chmod(0o600)
        (rollups_dir / "rollup.parquet").chmod(0o600)
        manifest = {
            "schema_version": 1,
            "hour_start": _iso(hour),
            "hour_end": _iso(hour + dt.timedelta(hours=1)),
            "input_files": input_files,
            "input_records": len(records),
            "job_output_records": len(records),
            "rollup_output_records": rollup_count,
            "completed_at": _iso(dt.datetime.now(dt.UTC)),
        }
        self.workspace.write_json_atomic(
            manifest_path,
            manifest,
        )

    def _advance_coverage(
        self,
        records_by_hour: dict[dt.datetime, list[tuple[Path, ValidatedEvent]]],
        cutoff: dt.datetime,
        now: dt.datetime,
        *,
        allow_advance: bool,
    ) -> None:
        state_path = self.root / "state/processor-state.json"
        state = json.loads(state_path.read_text())
        current = dt.datetime.fromisoformat(
            state["hourly_covered_through"].replace("Z", "+00:00")
        )
        target = cutoff.replace(minute=0, second=0, microsecond=0)
        eligible = {hour for hour in records_by_hour if hour < target}
        complete = all(
            (self.root / f"parquet/jobs/date={hour:%Y-%m-%d}/hour={hour:%H}/jobs.parquet").exists()
            and (self.root / f"parquet/hourly-rollups/date={hour:%Y-%m-%d}/hour={hour:%H}/rollup.parquet").exists()
            for hour in eligible
        )
        if allow_advance and complete:
            current = max(current, target)
        state.update(
            {
                "updated_at": _iso(now),
                "hourly_covered_through": _iso(current),
                "last_success_at": _iso(now),
                "last_error": None,
            }
        )
        self.workspace.write_json_atomic(state_path, state)

    def _quarantine(self, path: Path, error: Exception) -> Path:
        directory = self.root / "events/quarantine"
        destination = directory / path.name
        if destination.exists():
            destination = directory / f"{path.stem}-{os.getpid()}{path.suffix}"
        shutil.move(path, destination)
        self.workspace.write_json_atomic(
            destination.with_suffix(destination.suffix + ".error.json"),
            {
                "schema_version": 1,
                "quarantined_at": _iso(dt.datetime.now(dt.UTC)),
                "source": str(path),
                "error_class": type(error).__name__,
                "message": str(error)[:1024],
            },
        )
        return destination

    def _record_error(self, error: Exception) -> None:
        state_path = self.root / "state/processor-state.json"
        try:
            state = json.loads(state_path.read_text())
            state.update(
                {
                    "updated_at": _iso(dt.datetime.now(dt.UTC)),
                    "last_error": {
                        "error_class": type(error).__name__,
                        "message": str(error)[:1024],
                    },
                }
            )
            self.workspace.write_json_atomic(state_path, state)
        except Exception:
            pass

    def _apply_retention(self, now: dt.datetime) -> None:
        raw_cutoff = now - self.config.raw_retention
        for path in (self.root / "events/ready").glob("**/*.jsonl"):
            modified = dt.datetime.fromtimestamp(path.stat().st_mtime, dt.UTC)
            if modified < raw_cutoff:
                path.unlink(missing_ok=True)
        jobs_cutoff = now - self.config.jobs_retention
        for path in (self.root / "parquet/jobs").glob("date=*/hour=*/jobs.parquet"):
            try:
                day = dt.date.fromisoformat(path.parents[1].name.removeprefix("date="))
            except ValueError:
                continue
            if day < jobs_cutoff.date():
                path.unlink(missing_ok=True)

def _iso(value: dt.datetime) -> str:
    return value.astimezone(dt.UTC).isoformat(timespec="seconds").replace("+00:00", "Z")


def _hour_key(value: dt.datetime) -> str:
    return value.strftime("%Y-%m-%dT%H:00:00Z")


def _sql_literal(value: str) -> str:
    return value.replace("'", "''")
