"""Fail-closed ABBA raw-run validation, parity, and paired-cycle comparisons."""

import csv
import hashlib
import json
from pathlib import Path

from .power import power_failure
from .config import Cell, command
from .control_metrics import compare_cycle, distributions, metric_directions, row_latencies
from .provenance import digest, write_json
from .summary import dispersion, summarize_cell
from .validation import validate


def read_run(directory, manifest, expected_spec=None):
    spec = json.loads((directory / "spec.json").read_text())
    if expected_spec is not None and spec != expected_spec:
        raise ValueError("Existing run has a different workload/provenance contract")
    if spec.get("designProvenanceID") != manifest["provenanceID"]:
        raise ValueError("Run belongs to a different ABBA design")
    arm = manifest["arms"][spec["control"]["arm"]]
    design = manifest["design"]
    if (spec.get("cell") != arm["cell"] or spec.get("decodeTokens") != design["decodeTokens"]
            or spec.get("backend") != design["kvBackend"] or spec.get("iterations") != 1
            or spec.get("requiredACPowerMode") != 2):
        raise ValueError("Recorded run workload differs from its pinned arm")
    state = json.loads((directory / "process.json").read_text())
    expected_command = command(Path(arm["binary"]["path"]), design["modelID"], Path(arm["config"]["path"]),
                               Cell(arm["cell"]["phase"], arm["cell"]["context"], arm["cell"]["batch"]),
                               1, design["decodeTokens"], design["kvBackend"])
    if state.get("command") != expected_command:
        raise ValueError("Recorded process command differs from its pinned arm")
    if state.get("returncode") != 0 or any(state.get(key) for key in ("timedOut", "interrupted", "powerRequirementFailed")):
        raise ValueError(f"Process failed or incomplete: {state}")
    raw = directory / "stdout.raw"
    recorded = json.loads((directory / "validation.json").read_text())
    if recorded.get("valid") is not True or recorded.get("rawSHA256") != digest(raw):
        raise ValueError("Raw output changed or failed run-time validation")
    snapshots = {}
    for moment in ("before", "after"):
        snapshots[moment] = json.loads((directory / f"host-{moment}.json").read_text())
        failure = power_failure(snapshots[moment], 2)
        if failure:
            raise ValueError(f"{moment} power invalid: {failure}")
    report = json.loads(raw.read_text())
    validate(report, spec, arm)
    return spec, report, snapshots


def sequence_hash(tokens):
    return hashlib.sha256(json.dumps(tokens, separators=(",", ":")).encode()).hexdigest()


def summarize_controls(directory):
    manifest = json.loads((directory / "manifest.json").read_text())
    phase = manifest["arms"]["A"]["cell"]["phase"]
    prefill = phase == "prefill"
    directions = metric_directions(phase)
    observations, failures, hashes = [], [], {"A": {}, "B": {}}
    for planned in manifest["schedule"]:
        run_dir = directory / "runs" / planned["name"]
        try:
            spec, report, snapshots = read_run(run_dir, manifest)
            if spec["control"] != planned:
                raise ValueError("Recorded run position differs from planned ABBA order")
            row = summarize_cell(report, spec)
            if not prefill:
                row.update(row_latencies(report["decode"][0]["decodeTiming"]["rows"]))
            row.update({"run": planned["name"], **planned,
                        "thermalBefore": snapshots["before"].get("foundationThermalState"),
                        "thermalAfter": snapshots["after"].get("foundationThermalState")})
            observations.append(row)
            for token_row in ([] if prefill else report["decode"][0]["decodeTiming"]["rows"]):
                hashes[planned["arm"]].setdefault(str(token_row["row"]), {})[planned["name"]] = sequence_hash(token_row["tokenIDs"])
        except (ValueError, KeyError, OSError, TypeError, IndexError) as error:
            failures.append({"run": planned["name"], "error": str(error)})
    expected_names = {run["name"] for run in manifest["schedule"]}
    extras = {path.name for path in (directory / "runs").iterdir() if path.is_dir()} - expected_names
    failures += [{"run": name, "error": "Unplanned run directory"} for name in sorted(extras)]
    arm_summaries = {}
    for arm in ("A", "B"):
        selected = [row for row in observations if row["arm"] == arm]
        if selected:
            arm_summaries[arm] = {"label": manifest["arms"][arm]["label"], "runs": len(selected),
                                  **distributions(selected),
                                  "withinArmTokenExact": None if prefill else all(len(set(values.values())) == 1 for values in hashes[arm].values())}
    common_rows = sorted(set(hashes["A"]) & set(hashes["B"]), key=int)
    parity = {row: len(set(hashes["A"][row].values()) | set(hashes["B"][row].values())) == 1 for row in common_rows}
    cycle_comparisons = []
    for cycle in range(1, manifest["cycles"] + 1):
        selected = [row for row in observations if row["cycle"] == cycle]
        if len(selected) == 4:
            cycle_comparisons.append(compare_cycle(selected))
    complete = not failures and len(observations) == len(manifest["schedule"])
    expected_common = min(manifest["arms"][arm]["cell"]["batch"] for arm in ("A", "B"))
    token_exact = None if prefill else (complete and len(parity) == expected_common and all(parity.values())
                                       and all(arm_summaries[arm]["withinArmTokenExact"] for arm in ("A", "B")))
    same_shape = manifest["arms"]["A"]["cell"] == manifest["arms"]["B"]["cell"]
    result = {"schemaVersion": 1, "provenanceID": manifest["provenanceID"], "complete": complete,
              "phase": phase, "primaryMetric": "ttftMedianMs" if prefill else "aggregateDecodeTPS",
              "comparisonKind": "implementation" if same_shape else "batch-scaling",
              "tokenParityPassed": token_exact,
              "tokenParityStatus": "not_available_prefill_report" if prefill else "passed" if token_exact else "failed_or_incomplete",
              "validForPerformanceComparison": complete and (prefill or token_exact),
              "arms": arm_summaries, "runs": observations, "failures": failures,
              "cycleComparisons": cycle_comparisons,
              "cycleRatioDistribution": dispersion([c["ratioBOverA"] for c in cycle_comparisons]) if cycle_comparisons else None,
              "metricDirections": directions,
              "cycleMetricRatioDistributions": {name: dispersion([cycle["metrics"][name]["ratioBOverA"] for cycle in cycle_comparisons])
                                                  for name in directions
                                                  if cycle_comparisons and all(cycle["metrics"][name]["ratioBOverA"] is not None for cycle in cycle_comparisons)},
              "sharedRowParity": parity, "outputHashesByArmRowRun": hashes,
              "interpretation": "Every cycle executes A-B-B-A with one measured repetition per fresh process after its own shape warmup. Cycle ratios compare mean aggregate throughput of the two B runs with the two A runs. These are descriptive controls, not confidence intervals or evidence that thermal/background conditions were identical.",
              "timing": "Headlines use the host-observed common full-row decode window. Fair share is aggregate divided by batch. Stored-element totalParams/derived bandwidth interpretations are deliberately ignored.",
              "latency": "Row TTFT is first tokenArrivalMs minus submittedAtMs; row end-to-end latency is finishedAtMs minus submittedAtMs. Batch end-to-end runs from earliest submission to latest finish. Arm/cycle row distributions pool raw row latencies; cycle ratios average the two run medians for TTFT/row latency. TTFT, latency, and memory are lower-is-better only at comparable workload; decode throughput is higher-is-better.",
              "power": "AC Power and powermode 2 required before and after every run; Foundation thermal states are observations, not a throttle-free guarantee."}
    if prefill:
        result["interpretation"] = "Every cycle executes A-B-B-A with one measured single-request prefill per fresh process after full-context warmup. Primary cycle ratios compare mean B TTFT with mean A TTFT; below 1 is faster. These are descriptive timing controls, not confidence intervals or numerical-parity evidence."
        result["timing"] = "TTFT comes directly from scheduler-prefill samples; prompt throughput is context tokens divided by TTFT. No decode or terminal-latency metric is inferred."
        result["latency"] = "Prefill reports do not contain token IDs; token parity is unavailable and must be established separately. A valid prefill timing comparison is not a correctness verdict."
    write_json(directory / "comparison.json", result)
    columns = ["run", "cycle", "position", "arm", "context", "batch", "aggregateDecodeTPS", "fairShareDecodeTPS", "ttftMedianMs", "endToEndMedianMs", "batchEndToEndMs", "peakMemoryBytes"]
    if prefill:
        columns = ["run", "cycle", "position", "arm", "context", "batch", "ttftMedianMs", "promptTokensPerSecond", "peakMemoryBytes"]
    with (directory / "comparison.csv").open("w", newline="") as stream:
        writer = csv.DictWriter(stream, columns, extrasaction="ignore")
        writer.writeheader()
        writer.writerows(observations)
    lines = [f"# ABBA {phase} comparison", "", f"Complete: {complete}. Token parity: {result['tokenParityStatus']}.", "", result["interpretation"], "",
             "| Arm | Label | Runs | Median aggregate tok/s ↑ | CV | Median TTFT ms ↓ | Median batch end-to-end ms ↓ | Max peak GiB ↓ |",
             "|---|---|---:|---:|---:|---:|---:|---:|"]
    if prefill:
        lines[-2:] = ["| Arm | Label | Runs | Median TTFT ms ↓ | CV | Prompt tokens/s ↑ | Max peak GiB ↓ |",
                      "|---|---|---:|---:|---:|---:|---:|"]
    for arm, values in arm_summaries.items():
        cv = values[result["primaryMetric"]]["coefficientOfVariation"]
        cv_display = f"{cv:.2%}" if cv is not None else "unavailable"
        if prefill:
            lines.append(f"| {arm} | {values['label']} | {values['runs']} | {values['ttftMedianMs']['median']:.3f} | {cv_display} | {values['promptTokensPerSecond']['median']:.3f} | {values['peakMemoryBytes']['maximum']/2**30:.4f} |")
        else:
            lines.append(f"| {arm} | {values['label']} | {values['runs']} | {values['aggregateDecodeTPS']['median']:.3f} | {cv_display} | {values['ttftMedianMs']['median']:.3f} | {values['batchEndToEndMs']['median']:.3f} | {values['peakMemoryBytes']['maximum']/2**30:.4f} |")
    lines += ["", ("Cycle B/A TTFT ratios (below 1 is faster): " if prefill else "Cycle B/A aggregate ratios (above 1 is faster): ") + ", ".join(f"{c['ratioBOverA']:.5f}" for c in cycle_comparisons)]
    if not prefill:
        lines += ["", "Cycle B/A TTFT ratios (below 1 is faster): " + ", ".join(f"{c['metrics']['ttftMedianMs']['ratioBOverA']:.5f}" for c in cycle_comparisons)]
    lines += ["", result["timing"], "", result["latency"], "", result["power"]]
    if not complete or (not prefill and not token_exact):
        lines += ["", "No prefill timing conclusion is accepted until all scheduled runs validate." if prefill
                  else "No performance conclusion is accepted until all scheduled runs and output-parity checks pass."]
    lines += [f"\n- {failure['run']}: {failure['error']}" for failure in failures]
    (directory / "comparison.md").write_text("\n".join(lines) + "\n")
    return result
