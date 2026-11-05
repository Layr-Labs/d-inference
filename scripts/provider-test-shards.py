#!/usr/bin/env python3
"""Split the provider Swift test suites into CI selections and check that every test ran.

A selection is one serial `swift test` process. A CI job (a shard) runs
PROVIDER_TEST_PROCESSES selections at the same time (default 1: one selection
per job); job K of J runs selections (K-1)*P+1 .. K*P of N = J*P.
The parallel class is the test targets whose dependency closure has no MLX or
Metal (`PARALLEL_MODULES`); it runs in one process with Swift Testing's default
in-process parallelism, after selection 1. Every other suite stays serial
(`--no-parallel`). Prompt Parity runs in the job of selection `PARITY_SHARD`
against that job's build; the audit checks each parity run's executed count
against the suite list. Serial suites are assigned to selections by measured
seconds (`provider-test-shard-weights.json`, longest first onto the least
loaded selection). Selections 1..N-1 pick their assigned suites with
`--filter`; the last selection skips the parallel class and every other
selection's suites, so a suite that is new or missing from the weights always
runs there.

Subcommands:
  args SHARD ISOLATED    print the `swift test` selection for SHARD (`K/N` or
                         `parallel`), one argument per line; ISOLATED is the
                         run-provider-tests.sh isolated-process pattern
  counts SELECTION PATTERN LOG OUTPUT
                         write the executed test counts of one `swift test` run;
                         SELECTION is `K/N` or `parallel` with the isolated
                         pattern, or `parity` with the parity suite filter
  audit LIST REPORTS     check each selection executed exactly its planned tests
                         and that all of them together executed the full list
  audit-job LIST REPORTS K/N
                         the same for one CI job's own reports; job N also
                         checks that the plans cover the list once, and warns
                         about serial suites without measured seconds
  weights XUNIT...       print measured seconds per suite from xUnit reports;
                         suites they do not cover (SwiftPM writes no XCTest
                         xUnit report for a serial run) keep their seconds in
                         the checked-in weights
"""

import argparse
from collections import defaultdict
import json
import os
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
# CI runs Prompt Parity in the job that holds this selection: provider-tests.yml
# names that job (`matrix.shard == 1` with 3 processes), and
# test-provider-ci-workflow.py derives it from this value.
PARITY_SHARD = 2
# Measured seconds of fixed work outside the assigned suites: the parallel
# process runs after selection 1, in its process; Prompt Parity runs after
# the processes of PARITY_SHARD's job, and the isolated processes and native
# gates after those of the last job, so their seconds load every selection
# of that job.
FIRST_SHARD_EXTRA_SECONDS = 31.0
PARITY_SHARD_EXTRA_SECONDS = 65.0
LAST_SHARD_EXTRA_SECONDS = 190.0
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


def assignment(shards, weights, processes=1):
    """Return each selection's serial suites and estimated seconds.

    `shards` is the number of selections, `processes` how many of them one job
    runs at the same time. The last selection's list only balances the load:
    that selection runs every serial suite that selections 1..N-1 do not pick.
    """
    if shards % processes:
        raise ValueError(f"{shards} selections do not make jobs of {processes} processes")
    loads = [0.0] * shards
    loads[0] += FIRST_SHARD_EXTRA_SECONDS
    parity_job = (min(PARITY_SHARD, shards) - 1) // processes
    last_job = (shards - 1) // processes
    for index in range(shards):
        if index // processes == parity_job:
            loads[index] += PARITY_SHARD_EXTRA_SECONDS
        if index // processes == last_job:
            loads[index] += LAST_SHARD_EXTRA_SECONDS
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


def selection(shard, isolated, weights, processes=1):
    """Return (filter regex or None, skip regex) for one selection."""
    if shard == "parallel":
        return parallel_regex(), isolated
    index, shards = parse_shard(shard)
    assigned, _ = assignment(shards, weights, processes)
    if index < shards:
        if not assigned[index - 1]:
            raise ValueError(f"Shard {shard} has no suites; use fewer shards")
        return suites_regex(assigned[index - 1]), isolated
    others = [suites_regex(keys) for keys in assigned[:-1] if keys]
    return None, "|".join([parallel_regex(), *others, isolated])


def arguments(shard, isolated, weights, processes=1):
    selected, skipped = selection(shard, isolated, weights, processes)
    return (["--filter", selected] if selected else []) + ["--skip", skipped]


def planned(test_ids, shard, isolated, weights, processes=1):
    selected, skipped = selection(shard, isolated, weights, processes)
    return [test_id for test_id in test_ids
            if (selected is None or re.search(selected, test_id)) and not re.search(skipped, test_id)]


def counts(log_text, xctest_only=False):
    """Executed totals of one `swift test` run: Swift Testing and XCTest.

    A shard run always prints a Swift Testing summary; without one it did not
    finish. A parity selection of only XCTest cases (`xctest_only`) prints
    none, so there the XCTest summary is enough.
    """
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
    if not swift_testing and not (xctest_only and xctest is not None):
        raise ValueError("The log has no Swift Testing summary; the run did not finish")
    result = {"swift_testing": int(swift_testing[-1]) if swift_testing else 0, "xctest": xctest or 0}
    if not result["swift_testing"] + result["xctest"]:
        raise ValueError("The selection executed zero tests; the gate did not run")
    return result


def listed_tests(list_text):
    """Test identifiers from `swift test list`, one per line."""
    lines = {line.strip() for line in list_text.splitlines()}
    return sorted(line for line in lines if " " not in line and suite_key(line))


def audit(test_ids, reports, isolated, weights, processes=1):
    """Return error lines; empty when every selection ran exactly its planned tests."""
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
        plan = planned(test_ids, report["shard"], isolated, weights, processes)
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


def audit_job(test_ids, reports, isolated, weights, job, jobs, processes):
    """Return error lines for one CI job's own reports.

    Each job checks that every selection it ran executed exactly its planned
    tests, and its Prompt Parity runs if it had any. The last job also checks
    that the plans of all jobs together list every test once. With every job
    required to pass, that is the full-suite audit without a job of its own.
    """
    total = jobs * processes
    first, last = (job - 1) * processes + 1, job * processes
    expected = {"parallel"} if first == 1 else set()
    expected |= {f"{index}/{total}" for index in range(first, last + 1)}
    parity = [report for report in reports if report["shard"] == "parity"]
    own = [report for report in reports if report["shard"] != "parity"]
    errors = []
    if {report["shard"] for report in own} != expected or len(own) != len(expected):
        errors.append(f"Expected one report per selection {sorted(expected)}, got {sorted(r['shard'] for r in own)}")
    for report in own:
        if report.get("processes", 1) != processes:
            errors.append(f"Selection {report['shard']} was planned for {report.get('processes', 1)} processes, not {processes}")
        plan = planned(test_ids, report["shard"], isolated, weights, processes)
        ran = report["swift_testing"] + report["xctest"]
        print(f"selection {report['shard']}: planned {len(plan)}, executed {ran}")
        if ran != len(plan):
            errors.append(f"Selection {report['shard']} executed {ran} tests but its plan lists {len(plan)}")
    parity_job = (PARITY_SHARD - 1) // processes + 1
    if job == parity_job:
        errors += audit_parity(test_ids, parity)
    elif parity:
        errors.append(f"Prompt Parity ran in job {job}, not job {parity_job}")
    if job == jobs:
        expected_tests = [test_id for test_id in test_ids if not re.search(isolated, test_id)]
        seen = [test_id for selection in ("parallel", *(f"{index}/{total}" for index in range(1, total + 1)))
                for test_id in planned(test_ids, selection, isolated, weights, processes)]
        if len(seen) != len(set(seen)):
            errors.append(f"{len(seen) - len(set(seen))} tests are planned in more than one selection")
        if set(seen) != set(expected_tests):
            errors.append(f"{len(set(expected_tests) - set(seen))} listed tests are in no selection")
        print(f"all selections: plan {len(set(seen))} of {len(expected_tests)} listed tests "
              f"({len(test_ids) - len(expected_tests)} more run in isolated processes)")
    return errors


def unweighted(test_ids, weights):
    """Serial suites of the list without measured seconds; the last selection runs them all."""
    suites = {suite_key(test_id) for test_id in test_ids}
    return sorted(suite for suite in suites - set(weights)
                  if suite and "(" not in suite and suite.split(".", 1)[0] not in PARALLEL_MODULES)


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
    """Seconds per suite from xUnit reports. A retried selection's first
    attempt (attempt-1-shard-*.xml, run-provider-tests.sh) is not counted: its
    second attempt's report measures the same suites."""
    seconds = defaultdict(float)
    for path in paths:
        if Path(path).name.startswith("attempt-1-"):
            continue
        for case in ElementTree.parse(path).getroot().iter("testcase"):
            key = suite_key(case.get("classname", ""))
            if key:
                seconds[key] += float(case.get("time") or 0)
    measured = {key: round(value, 3) for key, value in seconds.items()}
    return dict(sorted({**(base or {}), **measured}.items()))


def processes_per_job():
    """PROVIDER_TEST_PROCESSES, the selections one job runs at the same time (default 1)."""
    value = os.environ.get("PROVIDER_TEST_PROCESSES") or "1"
    if not re.fullmatch(r"[1-9]", value):
        raise ValueError(f"PROVIDER_TEST_PROCESSES must be 1 to 9, got {value!r}")
    return int(value)


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
    command = commands.add_parser("audit-job")
    command.add_argument("list", type=Path)
    command.add_argument("reports", type=Path)
    command.add_argument("job", help="K/N: this job and the job count")
    command = commands.add_parser("weights")
    command.add_argument("xunit", type=Path, nargs="+")
    args = parser.parse_args()
    if args.command == "args":
        print("\n".join(arguments(args.shard, args.isolated, load_weights(), processes_per_job())))
    elif args.command == "counts":
        if args.shard not in ("parallel", "parity"):
            parse_shard(args.shard)
        # The report keeps the plan's process count, so the audit plans alike.
        report = {"shard": args.shard, "pattern": args.pattern, "processes": processes_per_job(),
                  **counts(args.log.read_text(errors="replace"), xctest_only=args.shard == "parity")}
        args.output.write_text(json.dumps(report))
    elif args.command == "audit":
        reports = [json.loads(path.read_text()) for path in sorted(args.reports.glob("*/shard-*.json"))]
        patterns = {report["pattern"] for report in reports if report["shard"] != "parity"}
        if len(patterns) != 1:
            print(f"::error::Shard reports disagree on the isolated-process pattern: {sorted(patterns)}")
            return 1
        processes = {report.get("processes", 1) for report in reports if report["shard"] != "parity"}
        if len(processes) != 1:
            print(f"::error::Shard reports disagree on the processes per job: {sorted(processes)}")
            return 1
        errors = audit(listed_tests(args.list.read_text()), reports, patterns.pop(), load_weights(),
                       processes.pop())
        for error in errors:
            print(f"::error::{error}")
        return 1 if errors else 0
    elif args.command == "audit-job":
        job, jobs = parse_shard(args.job)
        reports = [json.loads(path.read_text()) for path in sorted(args.reports.glob("shard-*.json"))]
        patterns = {report["pattern"] for report in reports if report["shard"] != "parity"}
        if len(patterns) != 1:
            print(f"::error::This job's reports disagree on the isolated-process pattern: {sorted(patterns)}")
            return 1
        test_ids, weights = listed_tests(args.list.read_text()), load_weights()
        errors = audit_job(test_ids, reports, patterns.pop(), weights, job, jobs, processes_per_job())
        for error in errors:
            print(f"::error::{error}")
        # Report-only: unweighted suites still run, but they unbalance the last selection.
        missing = unweighted(test_ids, weights) if job == jobs else []
        if missing:
            print(f"::warning title=Provider shard weights::{len(missing)} serial suites have no measured "
                  f"seconds, so the last selection runs them all ({', '.join(missing[:5])}"
                  f"{', ...' if len(missing) > 5 else ''}). Refresh scripts/provider-test-shard-weights.json "
                  "(docs/developer/test.md).")
        return 1 if errors else 0
    else:
        json.dump(measured_weights(args.xunit, load_weights()), sys.stdout, indent=0, sort_keys=True)
        print()
    return 0


if __name__ == "__main__":
    sys.exit(main())
