#!/usr/bin/env python3
"""Split the provider Swift test suites into CI shards and check that every test ran.

The parallel class is the test targets whose dependency closure has no MLX or
Metal (`PARALLEL_MODULES`); it runs in one process with Swift Testing's default
in-process parallelism. Every other suite stays serial (`--no-parallel`).
Prompt Parity runs in shard `PARITY_SHARD` against that shard's build; the
audit checks each parity run's executed count against the suite list.
Serial suites are assigned to shards by measured seconds
(`provider-test-shard-weights.json`, longest first onto the least loaded
shard). Shards 1..N-1 select their assigned suites with `--filter`; the last
shard skips the parallel class and every other shard's suites, so a suite that
is new or missing from the weights always runs there.

Subcommands:
  args SHARD ISOLATED    print the `swift test` selection for SHARD (`K/N` or
                         `parallel`), one argument per line; ISOLATED is the
                         run-provider-tests.sh isolated-process pattern
  counts SELECTION PATTERN LOG OUTPUT
                         write the executed test counts of one `swift test` run;
                         SELECTION is `K/N` or `parallel` with the isolated
                         pattern, or `parity` with the parity suite filter
  audit LIST REPORTS     check each shard executed exactly its planned tests and
                         that all shards together executed the full list
  weights XUNIT...       print measured seconds per suite from xUnit reports;
                         suites they do not cover (SwiftPM writes no XCTest
                         xUnit report for a serial run) keep their seconds in
                         the checked-in weights
"""

import argparse
from collections import defaultdict
import json
from pathlib import Path
import re
import sys
import xml.etree.ElementTree as ElementTree


WEIGHTS = Path(__file__).resolve().with_name("provider-test-shard-weights.json")
# Test targets whose dependency closure has no MLX, Metal or cluster runtime
# (provider-swift/Package.swift); test-provider-test-shards.py checks this.
PARALLEL_MODULES = (
    "DarkbloomFanCoreTests", "DarkbloomFanHelperTests", "DarkbloomFanServiceTests",
    "DarkbloomHardwareLoadTests", "DarkbloomPublishTests", "ProviderAppAttestTests",
    "ProviderCoreFoundationTests",
)
# Prompt Parity's suites, run with their artifacts required (scripts/verify-*-parity.sh).
PARITY_FILTERS = ("ProductionPromptParityTests", "NemotronTemplateParityLiveTests")
PARITY_SHARD = 2
# Measured seconds of fixed work outside the assigned suites: the parallel
# process runs in shard 1, Prompt Parity in shard PARITY_SHARD, and the
# isolated processes and native gates in the last shard.
FIRST_SHARD_EXTRA_SECONDS = 31.0
PARITY_SHARD_EXTRA_SECONDS = 65.0
LAST_SHARD_EXTRA_SECONDS = 150.0
# A test identifier starts with its module and its top-level suite or function.
SUITE = re.compile(r"^([^./]+)[./]([^./]+)")


def suite_key(test_id):
    match = SUITE.match(test_id)
    return f"{match.group(1)}.{match.group(2)}" if match else None


def parse_shard(value):
    match = re.fullmatch(r"([1-9][0-9]*)/([1-9][0-9]*)", value)
    if not match or int(match.group(1)) > int(match.group(2)):
        raise ValueError(f"Expected a shard K/N with 1 <= K <= N or 'parallel', got {value!r}")
    return int(match.group(1)), int(match.group(2))


def assignment(shards, weights):
    """Return each shard's serial suites and estimated seconds.

    The last shard's list only balances the load: that shard runs every serial
    suite that shards 1..N-1 do not select.
    """
    loads = [0.0] * shards
    loads[0] += FIRST_SHARD_EXTRA_SECONDS
    loads[min(PARITY_SHARD, shards) - 1] += PARITY_SHARD_EXTRA_SECONDS
    loads[-1] += LAST_SHARD_EXTRA_SECONDS
    assigned = [[] for _ in range(shards)]
    serial = {key: seconds for key, seconds in weights.items()
              if key.split(".", 1)[0] not in PARALLEL_MODULES}
    for key in sorted(serial, key=lambda key: (-serial[key], key)):
        index = min(range(shards), key=lambda index: (loads[index], index))
        loads[index] += serial[key]
        assigned[index].append(key)
    return assigned, loads


def suites_regex(keys):
    modules = defaultdict(list)
    for key in sorted(keys):
        module, suite = key.split(".", 1)
        modules[module].append(suite)
    alternatives = "|".join(f"{module}[./]({'|'.join(suites)})" for module, suites in modules.items())
    return f"^({alternatives})([./]|$)"


def parallel_regex():
    return f"^({'|'.join(PARALLEL_MODULES)})[./]"


def load_weights():
    weights = json.loads(WEIGHTS.read_text())
    for key, seconds in weights.items():
        if not SUITE.fullmatch(key) or not isinstance(seconds, (int, float)) or seconds < 0:
            raise ValueError(f"Invalid suite weight: {key!r}: {seconds!r}")
    return weights


def selection(shard, isolated, weights):
    """Return (filter regex or None, skip regex) for one shard."""
    if shard == "parallel":
        return parallel_regex(), isolated
    index, shards = parse_shard(shard)
    assigned, _ = assignment(shards, weights)
    if index < shards:
        if not assigned[index - 1]:
            raise ValueError(f"Shard {shard} has no suites; use fewer shards")
        return suites_regex(assigned[index - 1]), isolated
    others = [suites_regex(keys) for keys in assigned[:-1] if keys]
    return None, "|".join([parallel_regex(), *others, isolated])


def arguments(shard, isolated, weights):
    selected, skipped = selection(shard, isolated, weights)
    return (["--filter", selected] if selected else []) + ["--skip", skipped]


def planned(test_ids, shard, isolated, weights):
    selected, skipped = selection(shard, isolated, weights)
    return [test_id for test_id in test_ids
            if (selected is None or re.search(selected, test_id)) and not re.search(skipped, test_id)]


def counts(log_text):
    """Executed totals of one `swift test` run: Swift Testing and XCTest."""
    swift_testing = re.findall(r"Test run with (\d+) tests?\b", log_text)
    lines = log_text.splitlines()
    xctest = None
    for index, line in enumerate(lines):
        if re.search(r"Test Suite '(All tests|Selected tests)' (passed|failed) at", line):
            for following in lines[index + 1:index + 4]:
                match = re.search(r"Executed (\d+) tests?\b", following)
                if match:
                    xctest = int(match.group(1))
                    break
    # A selection of only XCTest cases prints no Swift Testing summary. A run
    # that stops early reports fewer tests than its selection lists, which the
    # audit refuses.
    if not swift_testing and xctest is None:
        raise ValueError("The log has no test run summary; the run did not finish")
    result = {"swift_testing": int(swift_testing[-1]) if swift_testing else 0, "xctest": xctest or 0}
    if not result["swift_testing"] + result["xctest"]:
        raise ValueError("The selection executed zero tests; the gate did not run")
    return result


def listed_tests(list_text):
    """Test identifiers from `swift test list`, one per line."""
    lines = {line.strip() for line in list_text.splitlines()}
    return sorted(line for line in lines if " " not in line and suite_key(line))


def audit(test_ids, reports, isolated, weights):
    """Return error lines; empty when every shard ran exactly its planned tests."""
    errors = audit_parity(test_ids, [report for report in reports if report["shard"] == "parity"])
    reports = [report for report in reports if report["shard"] != "parity"]
    expected = [test_id for test_id in test_ids if not re.search(isolated, test_id)]
    shards = {report["shard"] for report in reports}
    totals = {parse_shard(shard)[1] for shard in shards if shard != "parallel"}
    if len(totals) != 1:
        return errors + [f"Shard reports disagree on the shard count: {sorted(shards)}"]
    total = totals.pop()
    wanted = {"parallel", *(f"{index}/{total}" for index in range(1, total + 1))}
    if shards != wanted or len(reports) != len(wanted):
        errors.append(f"Expected one report per shard {sorted(wanted)}, got {sorted(r['shard'] for r in reports)}")
    executed = 0
    seen = []
    for report in sorted(reports, key=lambda report: report["shard"]):
        plan = planned(test_ids, report["shard"], isolated, weights)
        seen.extend(plan)
        ran = report["swift_testing"] + report["xctest"]
        executed += ran
        print(f"shard {report['shard']}: planned {len(plan)}, executed {ran} "
              f"({report['swift_testing']} Swift Testing, {report['xctest']} XCTest)")
        if ran != len(plan):
            errors.append(f"Shard {report['shard']} executed {ran} tests but its selection lists {len(plan)}")
    duplicates = len(seen) - len(set(seen))
    if duplicates:
        errors.append(f"{duplicates} tests are selected by more than one shard")
    if set(seen) != set(expected):
        errors.append(f"{len(set(expected) - set(seen))} listed tests are in no shard")
    print(f"all shards: executed {executed} of {len(expected)} listed tests "
          f"({len(test_ids) - len(expected)} more run in isolated processes)")
    if executed != len(expected):
        errors.append(f"The shards executed {executed} tests; the full suite lists {len(expected)}")
    return errors


def audit_parity(test_ids, reports):
    """Each Prompt Parity suite ran once, with every listed test of that suite."""
    errors = []
    filters = sorted(report["pattern"] for report in reports)
    if filters != sorted(PARITY_FILTERS):
        errors.append(f"Expected one Prompt Parity report per suite {sorted(PARITY_FILTERS)}, got {filters}")
    for report in reports:
        plan = [test_id for test_id in test_ids if re.search(report["pattern"], test_id)]
        ran = report["swift_testing"] + report["xctest"]
        print(f"parity {report['pattern']}: listed {len(plan)}, executed {ran}")
        if not plan or ran != len(plan):
            errors.append(f"Prompt Parity {report['pattern']} executed {ran} tests; the suite lists {len(plan)}")
    return errors


def measured_weights(paths, base=None):
    seconds = defaultdict(float)
    for path in paths:
        for case in ElementTree.parse(path).getroot().iter("testcase"):
            key = suite_key(case.get("classname", ""))
            if key:
                seconds[key] += float(case.get("time") or 0)
    measured = {key: round(value, 3) for key, value in seconds.items()}
    return dict(sorted({**(base or {}), **measured}.items()))


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    commands = parser.add_subparsers(dest="command", required=True)
    command = commands.add_parser("args")
    command.add_argument("shard")
    command.add_argument("isolated")
    command = commands.add_parser("counts")
    command.add_argument("shard")
    command.add_argument("pattern")
    command.add_argument("log", type=Path)
    command.add_argument("output", type=Path)
    command = commands.add_parser("audit")
    command.add_argument("list", type=Path)
    command.add_argument("reports", type=Path)
    command = commands.add_parser("weights")
    command.add_argument("xunit", type=Path, nargs="+")
    args = parser.parse_args()
    if args.command == "args":
        print("\n".join(arguments(args.shard, args.isolated, load_weights())))
    elif args.command == "counts":
        if args.shard not in ("parallel", "parity"):
            parse_shard(args.shard)
        report = {"shard": args.shard, "pattern": args.pattern,
                  **counts(args.log.read_text(errors="replace"))}
        args.output.write_text(json.dumps(report))
    elif args.command == "audit":
        reports = [json.loads(path.read_text()) for path in sorted(args.reports.glob("*/shard-*.json"))]
        patterns = {report["pattern"] for report in reports if report["shard"] != "parity"}
        if len(patterns) != 1:
            print(f"::error::Shard reports disagree on the isolated-process pattern: {sorted(patterns)}")
            return 1
        errors = audit(listed_tests(args.list.read_text()), reports, patterns.pop(), load_weights())
        for error in errors:
            print(f"::error::{error}")
        return 1 if errors else 0
    else:
        json.dump(measured_weights(args.xunit, load_weights()), sys.stdout, indent=0, sort_keys=True)
        print()
    return 0


if __name__ == "__main__":
    sys.exit(main())
