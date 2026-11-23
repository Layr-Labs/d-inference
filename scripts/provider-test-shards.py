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
loaded selection); a selection starts loaded with the fixed work its job
runs. A job's selections start together. Selections 1..N-1 pick
their assigned suites with `--filter`; the last selection skips the parallel
class and every other selection's suites, so a suite that is new or missing
from the weights always runs there.

Subcommands:
  args SHARD ISOLATED    print the `swift test` selection for SHARD (`K/N` or
                         `parallel`), one argument per line; ISOLATED is the
                         run-provider-tests.sh isolated-process pattern
  counts SELECTION PATTERN XUNIT STDOUT OUTPUT
                         write the executed test counts of one `swift test` run
                         from its Swift Testing xUnit report and its stdout
                         alone; SELECTION is `K/N` or `parallel` with the
                         isolated pattern, or `parity` with the parity suite
                         filter
  audit LIST REPORTS     check each selection executed exactly its planned tests
                         and that all of them together executed the full list
  audit-job LIST REPORTS K/N
                         the same for one CI job's own reports, and a warning
                         for each of its selections whose suites ran more than
                         STALE_SELECTION_SECONDS away from their weights; job N
                         also checks that the plans cover the list once and
                         that the weights cover the serial suites: it warns
                         about every serial suite without measured seconds and
                         fails when those suites ran more than
                         UNWEIGHTED_SECONDS_LIMIT in the last selection
  weights [--prune] REPORT...
                         print measured seconds per suite from xUnit reports
                         (Swift Testing) and selection logs (XCTest: SwiftPM
                         writes no XCTest xUnit report for a serial run);
                         suites they do not cover keep their seconds in the
                         checked-in weights, or with --prune (every
                         selection's reports and logs of one run) are dropped
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
    "DarkbloomHardwareLoadTests", "DarkbloomPublishTests", "DarkbloomSigningIdentityTests",
    "ProviderAppAttestTests", "ProviderCoreFoundationTests",
)
# Prompt Parity's suites, run with their artifacts required (scripts/verify-*-parity.sh).
PARITY_FILTERS = ("ProductionPromptParityTests", "NemotronTemplateParityLiveTests")
# CI runs Prompt Parity in the job that holds this selection: provider-tests.yml
# names that job (`matrix.shard == 1` with 3 processes), and
# test-provider-ci-workflow.py derives it from this value.
PARITY_SHARD = 2
# Measured seconds of fixed work outside the assigned suites: the parallel
# process runs after selection 1, in its process slot (12.4 s in runs
# 44696233902 and 44711129396); Prompt Parity runs after the processes of
# PARITY_SHARD's job (median 66 s over ten 4-shard runs), and the isolated
# processes (scripts/run-provider-tests.sh) after those of the last job
# (median 44 s, 36 to 57 s, in runs 44771184962, 44828405682, 44832255099,
# 44836403283 and 44843788822), so their seconds load every selection of that
# job. The other checks that ran once in the last job (the native gates) have
# a CI job of their own, Provider Gates, which runs beside the shards.
FIRST_SHARD_EXTRA_SECONDS = 13.0
PARITY_SHARD_EXTRA_SECONDS = 65.0
LAST_SHARD_EXTRA_SECONDS = 44.0
# The last job fails its audit when the serial suites without weights ran
# longer than this in the last selection, which runs them all: past it, that
# selection outgrows the others (11-19: 252 such suites, 495 s).
UNWEIGHTED_SECONDS_LIMIT = 60.0
# A job warns when one of its selections ran its suites this much longer or
# shorter than their weights: the plan no longer balances the jobs (in run
# 44696233902 selection 4 ran 402 s of suites weighed at 199 s, and its job
# ended 1.8 minutes after the next one).
STALE_SELECTION_SECONDS = 60.0
# A test identifier starts with its module and its top-level suite or function.
SUITE = re.compile(r"^([^./]+)[./]([^./]+)")
# One finished XCTest case in a `swift test` log.
XCTEST_CASE = re.compile(r"Test Case '-\[(\S+) (\S+)\]' (?:passed|failed|skipped) \((\d+(?:\.\d+)?) seconds\)")
# The end of XCTest's outermost suite; its `Executed N tests` follows.
XCTEST_RUN_END = re.compile(r"Test Suite '(All tests|Selected tests)' (passed|failed) at")


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
        job = index // processes
        if job == parity_job:
            loads[index] += PARITY_SHARD_EXTRA_SECONDS
        if job == last_job:
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


def counts(swift_testing_report, stdout_log):
    """Executed totals of one `swift test` run: Swift Testing and XCTest.

    Never from the merged console: SwiftPM writes its own warnings to stderr
    at no fixed point, so in one pipe a warning can land inside any line (run
    44909219943: `✔ Test run with 29` + warning + ` tests in 3 suites`).
    Swift Testing's count is the test cases of its xUnit report, skipped ones
    included, as its console summary counted them; Swift Testing writes the
    report when its run finishes, so without one the run did not finish. XCTest's
    count is its outermost suite's `Executed N tests` (skips included) in
    SwiftPM's stdout, which holds only the test process's output: without
    --parallel SwiftPM writes no XCTest report, and with it the report would
    count a skipped test as passed.
    """
    try:
        root = ElementTree.parse(swift_testing_report).getroot()
    except FileNotFoundError:
        raise ValueError(f"No Swift Testing xUnit report {swift_testing_report}; the run did not finish") from None
    except ElementTree.ParseError as error:
        raise ValueError(f"Unreadable Swift Testing xUnit report {swift_testing_report} ({error}); "
                         "the run did not finish") from None
    try:
        lines = Path(stdout_log).read_text(errors="replace").splitlines()
    except FileNotFoundError:
        raise ValueError(f"No stdout log {stdout_log}; the run did not finish") from None
    xctest = 0
    ends = [index for index, line in enumerate(lines) if XCTEST_RUN_END.search(line)]
    if ends:
        # Not only the next line: the test process's own stdout can arrive in between.
        executed = (re.search(r"Executed (\d+) tests?\b", line) for line in lines[ends[-1] + 1:])
        xctest = next((int(match.group(1)) for match in executed if match), 0)
    result = {"swift_testing": len(list(root.iter("testcase"))), "xctest": xctest}
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


def selection_suites(test_ids, isolated=None):
    """Suites of the listed tests that run in a selection (not only in an isolated process)."""
    return {suite_key(test_id) for test_id in test_ids
            if not (isolated and re.search(isolated, test_id))} - {None}


def unweighted(test_ids, weights, isolated=None):
    """Serial suites of the list without measured seconds; the last selection runs them all."""
    return sorted(suite for suite in selection_suites(test_ids, isolated) - set(weights)
                  if "(" not in suite and suite.split(".", 1)[0] not in PARALLEL_MODULES)


def stale(test_ids, weights, isolated=None):
    """Weights of suites that no selection runs: removed suites, or suites
    that run only in isolated processes. They load the planner with seconds
    no selection spends."""
    return sorted(set(weights) - selection_suites(test_ids, isolated))


def abbreviated(names):
    """The first five names, and an ellipsis when there are more."""
    return ", ".join(names[:5]) + (", ..." if len(names) > 5 else "")


def weight_drift(test_ids, weights, isolated, measured):
    """(warnings, errors) about the weights against the list and this run's seconds.

    `measured` is the seconds per suite of the last job's own reports, which
    hold the last selection: it runs every unweighted suite.
    """
    warnings, errors = [], []
    missing = unweighted(test_ids, weights, isolated)
    if missing:
        seconds = sum(measured.get(suite, 0.0) for suite in missing)
        message = (f"{len(missing)} serial suites have no measured seconds, so the last selection runs them all "
                   f"({seconds:.0f} s in this run, limit {UNWEIGHTED_SECONDS_LIMIT:.0f} s: "
                   f"{abbreviated(missing)}). Refresh "
                   "scripts/provider-test-shard-weights.json (docs/developer/test.md) or add the "
                   "entries this step prints.")
        (errors if seconds > UNWEIGHTED_SECONDS_LIMIT else warnings).append(message)
    unused = stale(test_ids, weights, isolated)
    if unused:
        warnings.append(f"{len(unused)} weights name suites no selection runs ({abbreviated(unused)}); "
                        "refresh with `weights --prune`.")
    return warnings, errors


def missing_entries(test_ids, weights, isolated, measured):
    """The weight entries this run measured for the unweighted suites."""
    return {suite: measured.get(suite, 0.0) for suite in unweighted(test_ids, weights, isolated)}


def stale_selection(shard, weights, processes, measured):
    """A warning when the suites the plan gives one selection ran more than
    STALE_SELECTION_SECONDS longer or shorter than their weights, else None.

    `measured` is the seconds per suite of that selection's own xUnit report
    and log. The last selection's unweighted suites are weight_drift's.
    """
    index, shards = parse_shard(shard)
    suites = assignment(shards, weights, processes)[0][index - 1]
    weighed = sum(weights[suite] for suite in suites)
    ran = sum(measured.get(suite, 0.0) for suite in suites)
    print(f"selection {shard}: its suites ran {ran:.0f} s, weighed {weighed:.0f} s")
    if abs(ran - weighed) <= STALE_SELECTION_SECONDS:
        return None
    furthest = sorted(suites, key=lambda suite: (-abs(measured.get(suite, 0.0) - weights[suite]), suite))[:3]
    changes = ", ".join(f"{suite} {weights[suite]:.0f} s -> {measured.get(suite, 0.0):.0f} s" for suite in furthest)
    return (f"Selection {shard} ran its suites for {ran:.0f} s, but their weights say {weighed:.0f} s ({changes}), "
            "so the plan no longer balances the jobs. Refresh scripts/provider-test-shard-weights.json "
            "(docs/developer/test.md).")


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


def measured_weights(paths, base=None, prune=False):
    """Seconds per suite from xUnit reports (`.xml`, Swift Testing) and
    `swift test` logs (any other file, XCTest's `Test Case` lines). An XCTest
    case counts once even when two logs hold it (a selection log and its
    process slot's output). Suites the reports do not measure keep their
    `base` seconds, unless `prune` drops them; prune needs logs, or every
    XCTest suite would go."""
    paths = [Path(path) for path in paths]
    xunit = [path for path in paths if path.suffix == ".xml"]
    logs = [path for path in paths if path.suffix != ".xml"]
    if prune and not logs:
        raise ValueError("--prune needs the selection logs too, or every XCTest suite loses its weight")
    seconds = defaultdict(float)
    for path in xunit:
        for case in ElementTree.parse(path).getroot().iter("testcase"):
            key = suite_key(case.get("classname", ""))
            if key:
                seconds[key] += float(case.get("time") or 0)
    xctest = {}
    for path in logs:
        for match in XCTEST_CASE.finditer(path.read_text(errors="replace")):
            xctest[match.group(1), match.group(2)] = float(match.group(3))
    for (case_class, _), value in xctest.items():
        key = suite_key(case_class)
        if key:
            seconds[key] += value
    measured = {key: round(value, 3) for key, value in seconds.items()}
    return dict(sorted({**({} if prune else base or {}), **measured}.items()))


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
    command.add_argument("xunit", type=Path, help="the Swift Testing report (<name>-swift-testing.xml)")
    command.add_argument("stdout", type=Path, help="SwiftPM's stdout alone, without its stderr")
    command.add_argument("output", type=Path)
    command = commands.add_parser("audit")
    command.add_argument("list", type=Path)
    command.add_argument("reports", type=Path)
    command = commands.add_parser("audit-job")
    command.add_argument("list", type=Path)
    command.add_argument("reports", type=Path)
    command.add_argument("job", help="K/N: this job and the job count")
    command = commands.add_parser("weights")
    command.add_argument("--prune", action="store_true",
                         help="drop the weights of suites the reports do not measure")
    command.add_argument("reports", type=Path, nargs="+",
                         help="xUnit reports (.xml) and selection logs (shard-*.log or slot-*.out)")
    args = parser.parse_args()
    if args.command == "args":
        print("\n".join(arguments(args.shard, args.isolated, load_weights(), processes_per_job())))
    elif args.command == "counts":
        if args.shard not in ("parallel", "parity"):
            parse_shard(args.shard)
        try:
            executed = counts(args.xunit, args.stdout)
        except ValueError as error:
            print(f"::error::Selection {args.shard}: {error}")
            return 1
        # The report keeps the plan's process count, so the audit plans alike.
        report = {"shard": args.shard, "pattern": args.pattern, "processes": processes_per_job(), **executed}
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
        test_ids, weights, isolated = listed_tests(args.list.read_text()), load_weights(), patterns.pop()
        processes = processes_per_job()
        errors = audit_job(test_ids, reports, isolated, weights, job, jobs, processes)
        for error in errors:
            print(f"::error::{error}")
        for report in reports:
            if report["shard"] in ("parallel", "parity"):
                continue
            name = report["shard"].replace("/", "-of-")
            own = [path for path in (args.reports / f"shard-{name}-swift-testing.xml", args.reports / f"shard-{name}.log")
                   if path.exists()]
            if not own:
                continue
            warning = stale_selection(report["shard"], weights, processes, measured_weights(own))
            if warning:
                print(f"::warning title=Provider shard weights::{warning}")
        if job == jobs:
            own = sorted([*args.reports.glob("shard-*.xml"), *args.reports.glob("shard-*.log")])
            measured = measured_weights(own)
            warnings, drift = weight_drift(test_ids, weights, isolated, measured)
            for warning in warnings:
                print(f"::warning title=Provider shard weights::{warning}")
            for error in drift:
                print(f"::error title=Provider shard weights::{error}")
            entries = missing_entries(test_ids, weights, isolated, measured)
            if entries:
                print("Measured seconds of the unweighted suites (entries for scripts/provider-test-shard-weights.json):")
                print("\n".join(f'"{suite}": {seconds},' for suite, seconds in entries.items()))
            errors += drift
        return 1 if errors else 0
    else:
        # --prune keeps no checked-in seconds, so it never reads the weights
        # file, and its output can replace that file directly.
        json.dump(measured_weights(args.reports, None if args.prune else load_weights(), args.prune), sys.stdout,
                  indent=0, sort_keys=True)
        print()
    return 0


if __name__ == "__main__":
    sys.exit(main())
