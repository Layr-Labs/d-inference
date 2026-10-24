#!/usr/bin/env python3
"""Sequential, offline driver for ModelCheckpointStorageLiveTests."""

import argparse
import copy
import datetime
import json
import os
from pathlib import Path
import subprocess
import sys
import uuid

from storage_summary import control_mismatches, summarize


PROFILES = (("native-live_native-checkpoint", "native", "native"),
            ("native-live_balanced-checkpoint", "native", "balanced"),
            ("balanced-live_balanced-checkpoint", "balanced", "balanced"))
ENVIRONMENT_KEYS = ("HOME", "PATH", "TMPDIR", "LANG", "LC_ALL", "LC_CTYPE",
                    "LC_COLLATE", "LC_MESSAGES", "LC_MONETARY", "LC_NUMERIC",
                    "LC_TIME", "TZ", "__CF_USER_TEXT_ENCODING")


def clean_environment(spec_path, framework_paths=(), library_paths=()):
    environment = {key: os.environ[key] for key in ENVIRONMENT_KEYS if key in os.environ}
    environment.update(DARKBLOOM_CHECKPOINT_STORAGE_BENCHMARK="1",
                       DARKBLOOM_PREFIX_EXCLUSIVE_GPU="1",
                       DARKBLOOM_CHECKPOINT_STORAGE_SPEC=str(spec_path))
    for key, paths in (("DYLD_FRAMEWORK_PATH", framework_paths), ("DYLD_LIBRARY_PATH", library_paths)):
        if paths:
            environment[key] = os.pathsep.join(str(Path(path).resolve()) for path in paths)
    return environment


def validate_base(base, pairs=None, warmups=None):
    if not isinstance(base, dict):
        raise ValueError("base specification must be a JSON object")
    base = copy.deepcopy(base)
    if pairs is not None:
        base["pairs"] = pairs
    if warmups is not None:
        base["warmupIterations"] = warmups
    for key in ("modelID", "openRouterID", "directory", "expectedWeightHash", "modelType", "outputPath"):
        if not isinstance(base.get(key), str) or not base[key].strip():
            raise ValueError(f"{key} must be a nonempty string")
    if not Path(base["directory"]).is_absolute():
        raise ValueError("directory must be an absolute local model path")
    for key, default, low, high in (("pairs", None, 1, 5), ("outputTokens", None, 32, 512),
                                    ("pairOffset", 0, 0, 4), ("warmupIterations", 1, 0, 5)):
        value = base.get(key, default)
        if type(value) is not int or not low <= value <= high:
            raise ValueError(f"{key} must be an integer in {low}...{high}")
    if base.get("pairOffset", 0) + base["pairs"] > 5:
        raise ValueError("pairOffset + pairs must not exceed 5")
    if base.get("captureTokenDiagnostics", False) is not False:
        raise ValueError("captureTokenDiagnostics must be false for performance runs")
    if base.get("kvBackend", "auto") not in ("auto", "contiguous", "paged"):
        raise ValueError("kvBackend must be auto, contiguous, or paged")
    cases = base.get("cases")
    if not isinstance(cases, list) or not 1 <= len(cases) <= 4:
        raise ValueError("cases must contain 1...4 cells")
    names = set()
    for cell in cases:
        if not isinstance(cell, dict) or not isinstance(cell.get("name"), str) or not cell["name"]:
            raise ValueError("each case needs a nonempty name")
        if cell["name"] in names:
            raise ValueError("case names must be unique for unambiguous pairing")
        names.add(cell["name"])
        tokens = [cell.get(key) for key in ("donorTokens", "sharedTokens", "forkTokens", "demandedTokens")]
        if any(type(value) is not int for value in tokens):
            raise ValueError("case token floors must be integers")
        donor, shared, fork, demanded = tokens
        if not (1024 <= demanded <= shared < min(donor, fork) and max(donor, fork) <= 20000):
            raise ValueError("case floors require 1024 <= demanded <= shared < donor/fork <= 20000")
    base["captureTokenDiagnostics"] = False
    return base


def plan_runs(base, output, command, include_balanced_live=False, access_group=None, refusal=False, reverse=False):
    run_id = str(uuid.uuid4())
    jobs = []
    profiles = PROFILES[:3 if include_balanced_live else 2]
    for profile, live, checkpoint in reversed(profiles) if reverse else profiles:
        directory = output / profile
        shared = {"runID": run_id}
        if access_group:
            shared.update(checkpointRoot=str(directory / "checkpoint-cache"),
                          keyNamespaceID=str(uuid.uuid4()), keyAccessGroup=access_group)
        steps = [("benchmark", "benchmark")] if not access_group else [("donate", "donate"), ("restore", "restore")]
        if refusal:
            steps += [("refuse", "refuse"), ("restore_after_refusal", "restore")]
        for step, phase in steps:
            benchmark = copy.deepcopy(base)
            benchmark.update(liveKVQuantization=live, checkpointQuantization=checkpoint,
                             outputPath=str(directory / f"{step}-report.json"))
            spec = dict(shared, benchmark=benchmark, phase=phase)
            if phase in ("restore", "refuse"):
                spec["producerReportPath"] = str(directory / "donate-report.json")
            jobs.append(dict(profile=profile, step=step, command=list(command), spec=spec,
                             specPath=str(directory / f"{step}-spec.json"),
                             stdoutLog=str(directory / f"{step}.stdout.log"),
                             stderrLog=str(directory / f"{step}.stderr.log")))
    return jobs


def report_problem(report, spec, producer=None):
    if not isinstance(report, dict):
        return "report is not a JSON object"
    if report.get("complete") is not True or report.get("failure") is not None:
        return f"report is incomplete: {report.get('failure')}"
    for key in ("runID", "phase", "checkpointRoot", "keyNamespaceID", "keyAccessGroup"):
        observed, expected = report.get(key), spec.get(key)
        if key in ("runID", "keyNamespaceID") and expected is not None:
            try:
                observed, expected = uuid.UUID(observed), uuid.UUID(expected)
            except (AttributeError, TypeError, ValueError):
                return f"invalid report UUID: {key}"
        if observed != expected:
            return f"report/spec mismatch: {key}"
    if type(report.get("processID")) is not int or report["processID"] <= 0:
        return "missing process identity"
    try:
        started = datetime.datetime.fromisoformat(report["startedAt"].replace("Z", "+00:00"))
        if started.tzinfo is None:
            return "startedAt must include a timezone"
    except (KeyError, AttributeError, TypeError, ValueError):
        return "invalid startedAt"
    expected = spec["benchmark"]
    benchmark = report.get("benchmark")
    if not isinstance(benchmark, dict) or not isinstance(benchmark.get("rows"), list) or not benchmark["rows"]:
        return "missing benchmark rows"
    if any(not isinstance(row, dict) or not isinstance(row.get("cell"), str)
           or not isinstance(row.get("role"), str) or type(row.get("pair")) is not int
           for row in benchmark["rows"]):
        return "invalid benchmark row identity"
    for key, source in (("modelID", "modelID"), ("openRouterID", "openRouterID"),
                        ("weightHash", "expectedWeightHash"), ("modelType", "modelType"),
                        ("outputTokens", "outputTokens"), ("liveKVQuantization", "liveKVQuantization"),
                        ("checkpointQuantization", "checkpointQuantization"),
                        ("requestedLiveKVQuantization", "liveKVQuantization"),
                        ("requestedCheckpointQuantization", "checkpointQuantization")):
        if benchmark.get(key) != expected[source]:
            return f"report/spec mismatch: benchmark.{key}"
    if control_mismatches(report, report) or not benchmark.get("checkpointBackendLayout"):
        return "missing actual model/runtime/backend/storage identity"
    try:
        artifact_directory = report.get("artifactDirectory")
        if (not isinstance(artifact_directory, str) or not Path(artifact_directory).is_absolute()
                or Path(artifact_directory).resolve() != Path(expected["directory"]).resolve()):
            return "report artifact directory differs from requested model"
    except (OSError, RuntimeError):
        return "report artifact directory cannot be resolved"
    if benchmark.get("cacheMode") != "ssd_complete" or benchmark.get("backendFallback") is not None or benchmark.get("keyMode") != (
            "persistent" if spec.get("keyAccessGroup") else "ephemeral"):
        return "fallback or incorrect key mode is not qualification evidence"
    if type(report.get("completedIterations")) is not int or report["completedIterations"] != len(expected["cases"]) * expected["pairs"]:
        return "completedIterations does not cover requested cells/pairs"
    warmups = expected.get("warmupIterations", 1) if spec["phase"] in ("benchmark", "donate") else 0
    if report.get("warmupIterations") != warmups:
        return "actual warmupIterations differs from this phase's request"
    if spec["phase"] in ("restore", "refuse") and (producer is None or producer.get("complete") is not True
            or producer.get("failure") is not None or producer.get("phase") != "donate"):
        return "restore/refuse requires a completed donor report"
    if producer is not None:
        fields = control_mismatches(producer, report)
        for key in ("liveKVQuantization", "checkpointQuantization", "checkpointBackendLayout"):
            if producer["benchmark"].get(key) != benchmark.get(key):
                fields.append(key)
        earlier = datetime.datetime.fromisoformat(producer["startedAt"].replace("Z", "+00:00"))
        if (fields or report.get("producerProcessID") != producer["processID"]
                or report["processID"] == producer["processID"] or started < earlier):
            return f"invalid distinct-process producer linkage or controls: {fields}"
    return report_evidence_problem(report, spec, producer)


def donation_controls_problem(report, base, indexed):
    controls = report.get("donationControls")
    if not isinstance(controls, list):
        return "missing donation controls"
    donors = {(cell, pair): row for (cell, pair, role), row in indexed.items() if role == "donor"}
    targets = {cell["name"]: cell["demandedTokens"] for cell in base["cases"]}
    seen = set()
    zero_counters = ("filesReadDelta", "bytesReadDelta", "restoredTokens", "matchedTokens", "replayTokens",
                     "stageConsumptionsDelta", "stagedBytesAfterRetirement", "writeHostBytesAfterRetirement",
                     "preemptions", "packedPrefillChunks")
    expected_witness = dict(state="ready", durableMode="ssd_complete", memoryEnabled=False,
                            maxStageBytes=1048576, manifestAllowanceBytes=1048576, checkpointFiles=0)
    for control in controls:
        if (not isinstance(control, dict) or not isinstance(control.get("cell"), str)
                or type(control.get("pair")) is not int):
            return "invalid donation control identity"
        key = control["cell"], control["pair"]
        if key not in donors or key in seen:
            return f"unexpected or duplicate donation control: {key}"
        seen.add(key)
        row = control.get("controlRow")
        if (not isinstance(row, dict) or row.get("cell") != key[0] or type(row.get("pair")) is not int
                or row["pair"] != key[1] or row.get("role") != "donation_control"):
            return f"invalid donation control row identity: {key}"
        metadata = control.get("benchmark")
        if not isinstance(metadata, dict) or metadata.get("rows") != []:
            return f"donation control requires row-empty benchmark metadata: {key}"
        fields = control_mismatches(report, dict(report, benchmark=metadata))
        for field in ("requestedLiveKVQuantization", "requestedCheckpointQuantization", "liveKVQuantization",
                      "checkpointQuantization", "checkpointBackendLayout", "executionStorage"):
            if metadata.get(field) is None or metadata.get(field) != report["benchmark"].get(field):
                fields.append(field)
        if not isinstance(metadata.get("executionStorage"), dict) or not metadata["executionStorage"]:
            fields.append("executionStorage")
        if metadata.get("assistantIdentity") != report["benchmark"].get("assistantIdentity"):
            fields.append("assistantIdentity")
        if fields:
            return f"donation control metadata mismatch: {key} {sorted(set(fields))}"
        if (type(control.get("warmupIterations")) is not int
                or control["warmupIterations"] != report.get("warmupIterations")):
            return f"donation control warmupIterations mismatch: {key}"
        witness = control.get("cacheWitness")
        if not isinstance(witness, dict) or any(
                type(witness.get(field)) is not type(value) or witness[field] != value
                for field, value in expected_witness.items()):
            return f"invalid donation control cache witness: {key}"
        donor = donors[key]
        for role, evidence in (("donation_control", row), ("donor", donor)):
            label = f"{key[0]}/{key[1]}/{role}"
            if (type(evidence.get("targetTokens")) is not int or evidence["targetTokens"] <= 0
                    or evidence["targetTokens"] != targets[key[0]]):
                return f"invalid matched donation targetTokens: {label}"
            if (type(evidence.get("promptTokens")) is not int or evidence["promptTokens"] <= 0
                    or evidence.get("prefixCacheEnabled") is not True
                    or type(evidence.get("samplingRequestID")) is not int or evidence["samplingRequestID"] != 11
                    or type(evidence.get("samplingTemperature")) not in (int, float) or evidence["samplingTemperature"] != 0
                    or type(evidence.get("stopTokenCount")) is not int or evidence["stopTokenCount"] != 0):
                return f"invalid matched donation request: {label}"
            scheduler = evidence.get("schedulerConfiguration")
            if (not isinstance(scheduler, dict) or not scheduler
                    or scheduler != report["benchmark"].get("schedulerConfiguration")):
                return f"matched donation schedulerConfiguration differs: {label}"
            if any(not isinstance(evidence.get(field), str) or not evidence[field].strip()
                   for field in ("promptSHA256", "outputSHA256", "cacheScopeSHA256")):
                return f"missing matched donation hash: {label}"
            mtp = evidence.get("mtp")
            if (type(evidence.get("completedOutputTokens")) is not int
                    or evidence["completedOutputTokens"] != base["outputTokens"]
                    or evidence.get("checkpointWritesDrained") is not True
                    or not isinstance(mtp, dict) or mtp.get("qualified") is not True):
                return f"incomplete matched donation output or retirement: {label}"
            if any(type(evidence.get(field)) is not int or evidence[field] != 0 for field in zero_counters):
                return f"matched donation unexpectedly read, restored, packed or retained state: {label}"
            writes = (evidence.get("filesWrittenDelta"), evidence.get("bytesWrittenDelta"))
            if any(type(value) is not int or (value != 0 if role == "donation_control" else value <= 0)
                   for value in writes):
                return f"invalid matched donation checkpoint writes: {label}"
            ranges = evidence.get("prefillRanges")
            if (not isinstance(ranges, list) or not ranges or type(evidence.get("prefillChunks")) is not int
                    or evidence["prefillChunks"] != len(ranges)):
                return f"missing or miscounted matched donation prefill ranges: {label}"
            cursor = 0
            for interval in ranges:
                if (not isinstance(interval, dict) or type(interval.get("lowerBound")) is not int
                        or type(interval.get("upperBound")) is not int or interval["lowerBound"] != cursor
                        or not 0 <= interval["lowerBound"] < interval["upperBound"] <= evidence["promptTokens"]
                        or interval.get("packed") is not False):
                    return f"invalid matched donation prefill range: {label}"
                if "plannedCap" in interval and (type(interval["plannedCap"]) is not int
                        or interval["plannedCap"] <= 0 or interval["plannedCap"] < interval["upperBound"] - cursor):
                    return f"invalid matched donation prefill cap: {label}"
                cursor = interval["upperBound"]
            if cursor != evidence["promptTokens"]:
                return f"incomplete matched donation prefill coverage: {label}"
        for field in ("targetTokens", "promptTokens", "promptSHA256", "outputSHA256", "cacheScopeSHA256", "prefillRanges"):
            if row[field] != donor[field]:
                return f"matched donation {field} differs: {key}"
    if seen != donors.keys():
        return "missing expected cell/pair donation controls"
    return None


def report_evidence_problem(report, spec, producer):
    if type(report.get("donationControlVersion")) is not int or report["donationControlVersion"] != 1:
        return "missing or unsupported donationControlVersion"
    if producer is not None:
        problem = report_problem(producer, dict(spec, phase="donate"))
        if problem:
            return f"invalid donor report: {problem}"
    phase, base = spec["phase"], spec["benchmark"]
    if phase in ("benchmark", "donate"):
        roles = ("cold_fork", "warm_full_prefill", "novel_donor", "donor", "ssd_restore",
                 "donor_ssd_restore", "donor_ssd_repeat", "other_tenant", "after_cancel_restore")
    elif phase == "restore":
        roles = ("ssd_restart_restore", "cold_fork", "warm_full_prefill", "donor_ssd_restore",
                 "other_tenant", "after_cancel_restore")
    else:
        roles = ("read_budget_refusal",)
    cells = {cell["name"]: cell for cell in base["cases"]}
    pairs = range(base.get("pairOffset", 0), base.get("pairOffset", 0) + base["pairs"])
    expected = {(cell, pair, role) for cell in cells for pair in pairs for role in roles}
    indexed = {}
    for row in report["benchmark"]["rows"]:
        key = row["cell"], row["pair"], row["role"]
        if key not in expected or key in indexed:
            return f"unexpected or duplicate row: {key}"
        indexed[key] = row
    if indexed.keys() != expected:
        return "missing expected cell/pair/role rows"
    ssd_roles = {"ssd_restore", "ssd_restart_restore", "donor_ssd_restore", "donor_ssd_repeat", "after_cancel_restore"}
    donor_roles = {"novel_donor", "donor", "donor_ssd_restore", "donor_ssd_repeat", "after_cancel_restore"}
    counters = ("promptTokens", "completedOutputTokens", "restoredTokens", "stageConsumptionsDelta",
                "filesWrittenDelta", "bytesWrittenDelta", "filesReadDelta", "bytesReadDelta",
                "stagedBytesAfterRetirement", "writeHostBytesAfterRetirement")
    for (cell, pair, role), row in indexed.items():
        label = f"{cell}/{pair}/{role}"
        if any(type(row.get(key)) is not int or row[key] < 0 for key in counters):
            return f"invalid or missing request counters: {label}"
        mtp = row.get("mtp")
        if (row["completedOutputTokens"] != base["outputTokens"] or row["promptTokens"] <= 0
                or row.get("checkpointWritesDrained") is not True or row["stagedBytesAfterRetirement"] != 0
                or row["writeHostBytesAfterRetirement"] != 0 or not isinstance(mtp, dict) or mtp.get("qualified") is not True):
            return f"incomplete output or request retirement: {label}"
        if any(not isinstance(row.get(key), str) or not row[key] for key in ("promptSHA256", "outputSHA256")):
            return f"missing prompt/output hash: {label}"
        writes = row["filesWrittenDelta"], row["bytesWrittenDelta"]
        if (role == "donor" and min(writes) <= 0) or (role != "donor" and any(writes)):
            return f"invalid checkpoint writes: {label}"
        if role in ssd_roles:
            if (row.get("stageDisposition") != "staged" or row["stageConsumptionsDelta"] != 1
                    or not cells[cell]["demandedTokens"] <= row["restoredTokens"] < row["promptTokens"]
                    or row["filesReadDelta"] <= 0 or row["bytesReadDelta"] <= 0):
                return f"missing staged SSD restore evidence: {label}"
            memory = row.get("memoryAtPrefillCompletion")
            if (not isinstance(memory, dict) or memory.get("observationPoint") != "engine_queue_prefill_completion"
                    or type(row.get("samplingRequestID")) is not int or row["samplingRequestID"] != 11
                    or any(type(memory.get(field)) is not int or memory[field] != expected for field, expected in (
                        ("callbackCount", 1), ("requestID", row["samplingRequestID"]),
                        ("promptTokens", row["promptTokens"]), ("restoredTokens", row["restoredTokens"])))
                    or any(type(memory.get(field)) is not int or memory[field] <= 0
                           for field in ("backendBytesInUse", "backendBytesCapacity"))
                    or type(memory.get("backendBytesReserved")) is not int or memory["backendBytesReserved"] < 0
                    or any(field in memory for field in ("kvBytesInUse", "kvBytesReserved", "kvBytesCapacity"))
                    or any(field in memory and (type(memory[field]) is not int or memory[field] < 0)
                           for field in ("pagedCommittedBytes", "pagedLiveBytes", "pagedReservedBytes"))):
                return f"invalid engine-queue prefill memory evidence: {label}"
            if "pagedGeneration" in memory:
                try:
                    uuid.UUID(memory["pagedGeneration"])
                except (AttributeError, TypeError, ValueError):
                    return f"invalid prefill memory pagedGeneration: {label}"
        elif role == "read_budget_refusal":
            if (row["restoredTokens"] != 0 or row["stageConsumptionsDelta"] != 0
                    or row.get("stageDisposition") not in ("miss_absent", "skipped_capacity")):
                return f"invalid read-budget refusal: {label}"
        elif any(row[key] for key in ("restoredTokens", "stageConsumptionsDelta", "filesReadDelta", "bytesReadDelta")):
            return f"fresh prefill unexpectedly restored or read: {label}"
    problem = donation_controls_problem(report, base, indexed)
    if problem:
        return problem
    for cell in cells:
        for pair in pairs:
            rows = {role: indexed[cell, pair, role] for role in roles}
            donor_hashes = {row["promptSHA256"] for role, row in rows.items() if role in donor_roles}
            fork_hashes = {row["promptSHA256"] for role, row in rows.items() if role not in donor_roles}
            if len(donor_hashes) > 1 or len(fork_hashes) > 1 or donor_hashes & fork_hashes:
                return f"donor/fork prompt hashes disagree: {cell}/{pair}"
            for group in (("cold_fork", "warm_full_prefill", "other_tenant"),
                          ("donor_ssd_restore", "donor_ssd_repeat", "after_cancel_restore")):
                if len({rows[role]["outputSHA256"] for role in group if role in rows}) > 1:
                    return f"same-profile output hashes disagree: {cell}/{pair} {group}"
            if producer is not None:
                sources = {row["role"]: row for row in producer["benchmark"]["rows"] if row["cell"] == cell and row["pair"] == pair}
                links = (("ssd_restart_restore", "ssd_restore"), ("donor_ssd_restore", "donor_ssd_restore")) if phase == "restore" else (
                    ("read_budget_refusal", "ssd_restore"),)
                fields = ("promptSHA256",) if phase == "refuse" else ("promptSHA256", "outputSHA256")
                for target, source in links:
                    if source not in sources or any(rows[target][key] != sources[source].get(key) for key in fields):
                        return f"producer {source} does not match {target}: {cell}/{pair}"
    cancellations = report.get("cancellations")
    if not isinstance(cancellations, list):
        return "missing cancellation witnesses"
    expected_cancels = {(cell, pair) for cell in cells for pair in pairs} if phase != "refuse" else set()
    seen = set()
    for witness in cancellations:
        if not isinstance(witness, dict) or not isinstance(witness.get("cell"), str) or type(witness.get("pair")) is not int:
            return "invalid cancellation identity"
        key = witness["cell"], witness["pair"]
        if key not in expected_cancels or key in seen:
            return f"unexpected or duplicate cancellation: {key}"
        seen.add(key)
        memory = witness.get("memoryAfterRetirement")
        if (witness.get("cancellationIssued") is not True or witness.get("cancelledTerminalObserved") is not True
                or type(witness.get("outputTokensBeforeTerminal")) is not int or witness["outputTokensBeforeTerminal"] <= 0
                or witness.get("stageDisposition") != "staged" or type(witness.get("restoredTokens")) is not int
                or witness["restoredTokens"] < cells[key[0]]["demandedTokens"] or witness.get("stagedBytesAfterRetirement") != 0
                or type(witness.get("filesWrittenDelta")) is not int or witness["filesWrittenDelta"] != 0
                or type(witness.get("bytesWrittenDelta")) is not int or witness["bytesWrittenDelta"] != 0
                or witness.get("writeHostBytesAfterRetirement") != 0 or not isinstance(memory, dict)
                or memory.get("kvBytesInUse") != 0 or memory.get("kvBytesReserved") != 0):
            return f"incomplete cancellation/retirement evidence: {key}"
    if seen != expected_cancels:
        return "missing expected cell/pair cancellation witnesses"
    if phase != "benchmark":
        artifacts = report.get("authenticatedArtifacts")
        if not isinstance(artifacts, list) or not artifacts:
            return "persistent phases require authenticated artifacts, not directory presence"
        for artifact in artifacts:
            if (not isinstance(artifact, dict) or artifact.get("backendLayout") != report["benchmark"]["checkpointBackendLayout"]
                    or any(type(artifact.get(key)) is not int or artifact[key] <= 0 for key in ("encryptedFileBytes", "encodedTensorBytes"))):
                return "invalid authenticated artifact bytes or backend layout"
    if phase == "refuse":
        artifacts = producer.get("authenticatedArtifacts")
        if not isinstance(artifacts, list) or not artifacts or any(
                not isinstance(artifact, dict) or type(artifact.get("encryptedFileBytes")) is not int
                or artifact["encryptedFileBytes"] <= 2 << 20 for artifact in artifacts):
            return "read refusal requires every producer encrypted artifact above 2 MiB"
    return None


def write_json(path, value):
    with Path(path).open("x", encoding="utf-8") as stream:
        json.dump(value, stream, indent=2, sort_keys=True, allow_nan=False)
        stream.write("\n")


def execute(jobs, output, root, framework_paths=(), library_paths=()):
    output.mkdir()  # Refuse reuse, including existing or symlinked output roots.
    for profile in dict.fromkeys(job["profile"] for job in jobs):
        (output / profile).mkdir()
    for cache in dict.fromkeys(job["spec"].get("checkpointRoot") for job in jobs):
        if cache:
            Path(cache).mkdir()
    write_json(output / "plan.json", jobs)
    records, producers = [], {}
    for job in jobs:
        spec = job["spec"]
        write_json(job["specPath"], spec)
        record = {key: value for key, value in job.items() if key != "spec"}
        record.update(phase=spec["phase"], reportPath=spec["benchmark"]["outputPath"], returnCode=None)
        producer = producers.get(job["profile"])
        if spec.get("producerReportPath") and producer is None:
            record.update(status="skipped", error="donate did not produce an accepted complete report")
        else:
            try:
                with Path(job["stdoutLog"]).open("x") as stdout, Path(job["stderrLog"]).open("x") as stderr:
                    process = subprocess.run(job["command"], cwd=root, stdout=stdout, stderr=stderr,
                                             env=clean_environment(job["specPath"], framework_paths, library_paths),
                                             check=False, shell=False)
                record["returnCode"] = process.returncode
                try:
                    with Path(record["reportPath"]).open(encoding="utf-8") as stream:
                        report = json.load(stream)
                    problem = report_problem(report, spec, producer)
                    status = "report_invalid" if problem else "complete"
                except FileNotFoundError:
                    report, problem, status = None, "report file absent", "report_absent"
                except (OSError, ValueError) as error:
                    report, problem, status = None, str(error), "report_invalid"
                if process.returncode:
                    problem, status = f"process exited {process.returncode}; {problem or 'report not accepted'}", "process_failed"
                record.update(status=status)
                if status == "complete":
                    record["report"] = report
                    if spec["phase"] == "donate":
                        producers[job["profile"]] = report
                else:
                    record["error"] = problem
            except OSError as error:
                record.update(status="launch_failed", error=str(error))
        records.append(record)
        # Preserve accepted earlier reports even if a later process is interrupted.
        write_json(output / ".summary.tmp", summarize(records))
        (output / ".summary.tmp").replace(output / "summary.json")
    return 0 if all(record["status"] == "complete" for record in records) else 1


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--spec", required=True, type=Path, help="standalone ModelPrefixBenchmarkSpecification JSON")
    parser.add_argument("--output-dir", required=True, type=Path, help="new directory; its parent must exist")
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[2], help="repository root")
    parser.add_argument("--pairs", type=int, help="override base pairs (1...5, including pairOffset bound)")
    parser.add_argument("--warmup-iterations", type=int, help="override base warmupIterations (0...5)")
    parser.add_argument("--include-balanced-live", action="store_true", help="also run the old balanced live/checkpoint profile")
    parser.add_argument("--reverse-profile-order", action="store_true", help="reverse profile order for a fresh counterbalanced run")
    parser.add_argument("--persistent-access-group", help="explicit signed test keychain access group; enables process restart")
    parser.add_argument("--exercise-read-refusal", action="store_true", help="after restart, refuse a capped read then restore again")
    parser.add_argument("--test-command-json", help="parent-provided signed launcher argv JSON; never interpreted by a shell")
    parser.add_argument("--framework-path", action="append", default=[], help="explicit DYLD_FRAMEWORK_PATH entry for custom launcher")
    parser.add_argument("--library-path", action="append", default=[], help="explicit DYLD_LIBRARY_PATH entry for custom launcher")
    parser.add_argument("--dry-run", action="store_true", help="print commands/specs only; create nothing and launch nothing")
    args = parser.parse_args(argv)
    try:
        if args.exercise_read_refusal and not args.persistent_access_group:
            raise ValueError("--exercise-read-refusal requires --persistent-access-group")
        if args.persistent_access_group is not None and not args.persistent_access_group.strip():
            raise ValueError("--persistent-access-group must be nonempty")
        if (args.framework_path or args.library_path) and not args.test_command_json:
            raise ValueError("explicit framework/library paths require --test-command-json")
        with args.spec.open(encoding="utf-8") as stream:
            base = validate_base(json.load(stream), args.pairs, args.warmup_iterations)
        root, output = args.root.resolve(), args.output_dir.absolute()
        command = json.loads(args.test_command_json) if args.test_command_json else [
            "swift", "test", "--package-path", str(root / "provider-swift"), "--skip-build",
            "--disable-automatic-resolution", "--filter", "ModelCheckpointStorageLiveTests"]
        if not isinstance(command, list) or not command or any(
                not isinstance(arg, str) or not arg or "\0" in arg for arg in command):
            raise ValueError("--test-command-json must be a nonempty argv array of nonempty strings")
        jobs = plan_runs(base, output, command, args.include_balanced_live,
                         args.persistent_access_group, args.exercise_read_refusal, args.reverse_profile_order)
        if args.dry_run:
            print(json.dumps(jobs, indent=2, sort_keys=True, allow_nan=False))
            return 0
        result = execute(jobs, output, root, args.framework_path, args.library_path)
        print(output / "summary.json")
        return result
    except (OSError, ValueError) as error:
        parser.error(str(error))


if __name__ == "__main__":
    sys.exit(main())
