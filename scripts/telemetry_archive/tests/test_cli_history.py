import json

import pytest

from telemetry_archive import cli


def test_prepare_plan_preserves_explicit_capture_generation(tmp_path):
    ranges = tmp_path / "ranges.json"
    ranges.write_text(json.dumps([{"table": "usage", "id_start": 1, "id_end": 10}]))
    output = tmp_path / "plan.json"
    args = cli.parser().parse_args(
        [
            "prepare-plan",
            "--ranges",
            str(ranges),
            "--output",
            str(output),
            "--capture-generation",
            "refresh-2026-10-05",
        ]
    )
    result = cli.execute(args)
    assert result["capture_generation"] == "refresh-2026-10-05"
    assert json.loads(output.read_text()) == result


@pytest.mark.parametrize(
    "command,function",
    [
        ("query-submit", "submit"),
        ("query-status", "status"),
        ("query-cancel", "cancel"),
    ],
)
def test_async_query_commands_dispatch_without_starting_other_work(monkeypatch, command, function):
    argv = [command, "--project", "archive-test", "--job-id", "archive-query-test"]
    if command == "query-submit":
        argv += [
            "--dataset",
            "accounting_history",
            "--catalog",
            "a" * 16,
            "--tables",
            "usage",
            "--sql-file",
            "query.sql",
        ]
    expected = {"job_id": "archive-query-test", "state": "RUNNING"}
    calls = []

    def execute(args):
        calls.append(args)
        return expected

    monkeypatch.setattr(cli.async_query, function, execute)
    args = cli.parser().parse_args(argv)
    assert cli.execute(args) == expected
    assert calls == [args]
    assert args.location == "us-east4"
    if command == "query-status":
        assert args.max_results == 100
        assert args.page_token is None
