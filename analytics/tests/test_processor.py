import datetime as dt
import json
import tempfile
import unittest
from pathlib import Path

import duckdb

from darkbloom_analytics.processor import Processor, ProcessorConfig
from test_schema import event


class ProcessorTests(unittest.TestCase):
    def test_hourly_parquet_rollup_and_rill_union(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            processor = Processor(ProcessorConfig(root=root))
            processor.initialize()
            now = dt.datetime.now(dt.UTC).replace(minute=10, second=0, microsecond=0)
            hour = now.replace(minute=0) - dt.timedelta(hours=1)
            ready = root / f"events/ready/date={hour:%Y-%m-%d}"
            ready.mkdir(parents=True)
            segment = ready / "events-test.jsonl"
            values = [
                event(
                    event_id="event-1",
                    job_id="job-1",
                    event_at=(hour + dt.timedelta(minutes=5)).isoformat().replace("+00:00", "Z"),
                ),
                event(
                    event_id="event-2",
                    job_id="job-2",
                    event_at=(hour + dt.timedelta(minutes=6)).isoformat().replace("+00:00", "Z"),
                    completion_tokens=8,
                ),
            ]
            segment.write_text("".join(json.dumps(value) + "\n" for value in values))

            result = processor.run(now=now)
            self.assertEqual(len(result.processed_hours), 1)
            jobs = root / f"parquet/jobs/date={hour:%Y-%m-%d}/hour={hour:%H}/jobs.parquet"
            rollup = root / f"parquet/hourly-rollups/date={hour:%Y-%m-%d}/hour={hour:%H}/rollup.parquet"
            self.assertTrue(jobs.exists())
            self.assertTrue(rollup.exists())

            connection = duckdb.connect(":memory:")
            self.assertEqual(connection.execute(
                "SELECT count(*), sum(completion_tokens) FROM read_parquet(?)", [str(jobs)]
            ).fetchone(), (2, 13))
            self.assertEqual(connection.execute(
                "SELECT sum(jobs), sum(completion_tokens) FROM read_parquet(?)", [str(rollup)]
            ).fetchone(), (2, 13))

            rill = root / "rill/models"
            for name in ("analytics_coverage", "jobs_history", "jobs_live", "jobs_all"):
                sql = (rill / f"{name}.sql").read_text()
                connection.execute(f"CREATE VIEW {name} AS {sql}")
            self.assertEqual(connection.execute("SELECT count(*) FROM jobs_all").fetchone()[0], 2)
            connection.close()

            second = processor.run(now=now)
            self.assertEqual(second.processed_hours, result.processed_hours)

    def test_malformed_segment_is_quarantined(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            processor = Processor(ProcessorConfig(root=root))
            processor.initialize()
            ready = root / "events/ready/date=2026-08-27"
            ready.mkdir(parents=True)
            bad = ready / "bad.jsonl"
            bad.write_text('{"prompt":"secret"}\n')
            result = processor.run()
            self.assertEqual(len(result.quarantined_files), 1)
            self.assertFalse(bad.exists())

    def test_processes_swift_codable_shape_with_omitted_nil_fields(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            processor = Processor(ProcessorConfig(root=root))
            processor.initialize()
            now = dt.datetime.now(dt.UTC).replace(minute=10, second=0, microsecond=0)
            hour = now.replace(minute=0) - dt.timedelta(hours=1)
            ready = root / f"events/ready/date={hour:%Y-%m-%d}"
            ready.mkdir(parents=True)
            value = event(
                event_at=(hour + dt.timedelta(minutes=5)).isoformat().replace("+00:00", "Z"),
                outcome="failed",
                event_name="inference.failed",
                error_class="generation",
            )
            for key in (
                "trace_id", "queue_ms", "ttft_ms", "decode_tps",
                "earned_micro_usd", "kv_backend", "mtp_active",
            ):
                value.pop(key)
            segment = ready / "swift-event.jsonl"
            segment.write_text(json.dumps(value) + "\n")

            result = processor.run(now=now)

            self.assertEqual(len(result.processed_hours), 1)
            self.assertEqual(result.quarantined_files, ())
            jobs = root / f"parquet/jobs/date={hour:%Y-%m-%d}/hour={hour:%H}/jobs.parquet"
            row = duckdb.connect(":memory:").execute(
                "SELECT trace_id, queue_ms, kv_backend FROM read_parquet(?)", [str(jobs)]
            ).fetchone()
            self.assertEqual(row, (None, None, None))


if __name__ == "__main__":
    unittest.main()
