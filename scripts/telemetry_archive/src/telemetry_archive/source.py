"""Bounded read-only snapshots from a physical PostgreSQL replica."""

import time
from contextlib import contextmanager

import psycopg
from psycopg import sql

from .model import TABLES, ArchiveError, Window, stamp


@contextmanager
def snapshot(dsn: str, window: Window, *, require_replica: bool = True):
    """require_replica=False is only used by disposable-database integration tests."""
    options = (
        "-c default_transaction_read_only=on -c statement_timeout=15000 "
        "-c lock_timeout=1000 -c idle_in_transaction_session_timeout=30000 "
        "-c timezone=UTC -c datestyle=ISO,YMD -c extra_float_digits=3"
    )
    with psycopg.connect(
        dsn,
        autocommit=True,
        connect_timeout=10,
        options=options,
        application_name="telemetry-archive-copy-only",
    ) as conn:
        conn.execute("BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY")
        try:
            recovery, readonly, observed, database, snapshot_id = conn.execute(
                "SELECT pg_is_in_recovery(), current_setting('transaction_read_only'), "
                "clock_timestamp(), current_database(), pg_current_snapshot()::text"
            ).fetchone()
            if readonly != "on" or (require_replica and not recovery):
                raise ArchiveError("source must be a read-only physical replica")
            started = time.monotonic()
            columns = conn.execute(
                "SELECT a.attname, format_type(a.atttypid, a.atttypmod), a.attnotnull "
                "FROM pg_attribute a JOIN pg_class c ON c.oid=a.attrelid "
                "JOIN pg_namespace n ON n.oid=c.relnamespace "
                "WHERE n.nspname='public' AND c.relname=%s "
                "AND c.relkind='r' AND a.attnum>0 AND NOT a.attisdropped ORDER BY a.attnum",
                (window.table,),
            ).fetchall()
            if not columns:
                raise ArchiveError("source table is absent")
            metadata = {
                "database": database,
                "in_recovery": recovery,
                "read_only": readonly,
                "observed_at": stamp(observed),
                "snapshot": snapshot_id,
                "columns": [
                    {"name": name, "postgres_type": kind, "not_null": not_null}
                    for name, kind, not_null in columns
                ],
            }
            table = sql.Identifier("public", window.table)
            timestamp = sql.Identifier(TABLES[window.table])
            predicate = sql.SQL("{t} >= %s AND {t} < %s").format(t=timestamp)
            expected = conn.execute(
                sql.SQL("SELECT COUNT(*) FROM {table} WHERE {predicate}").format(
                    table=table, predicate=predicate
                ),
                (window.start, window.end),
            ).fetchone()[0]
            if expected > window.max_rows:
                raise ArchiveError("window exceeds max_rows; split it into smaller intervals")
            with conn.cursor(name="telemetry_archive_rows") as cursor:
                cursor.execute(
                    sql.SQL(
                        "SELECT id, {t}, row_to_json(s)::text FROM {table} s "
                        "WHERE {predicate} ORDER BY {t}, id"
                    ).format(t=timestamp, table=table, predicate=predicate),
                    (window.start, window.end),
                )

                def pages():
                    while True:
                        if time.monotonic() - started > window.max_seconds:
                            raise ArchiveError("snapshot duration limit reached; reduce the window")
                        rows = cursor.fetchmany(window.page_rows)
                        if not rows:
                            return
                        yield rows

                yield metadata, expected, pages()
        finally:
            conn.execute("ROLLBACK")
