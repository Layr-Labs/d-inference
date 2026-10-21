"""Observed metrics only; incompatible controls never produce paired ratios."""

from collections import defaultdict
import math
import statistics


NATIVE = "native-live_native-checkpoint"
CONTROL_FIELDS = ("modelID", "openRouterID", "weightHash", "modelType", "servingModelType",
                  "backend", "runtimeIdentity", "cacheMode", "keyMode", "mtpEnabled",
                  "checkpointPartition", "strictFsync", "productionKVGrantBytes", "physicalMemoryBytes",
                  "activationReserveBytes", "outputTokens", "schedulerConfiguration")
METRICS = ("firstOutputSeconds", "generationTPS", "terminalSeconds", "receiptCompletionSeconds",
           "quiescenceCompletionSeconds", "stageMilliseconds", "restoredTokens", "filesReadDelta",
           "bytesReadDelta", "filesWrittenDelta", "bytesWrittenDelta", "decodeSteps", "chainedDecodeSteps") + tuple(
               "memoryAtPrefillCompletion." + key for key in ("backendBytesInUse", "backendBytesReserved",
                                                              "backendBytesCapacity", "pagedCommittedBytes",
                                                              "pagedLiveBytes", "pagedReservedBytes"))


def control_mismatches(left, right):
    a, b = left["benchmark"], right["benchmark"]
    mismatches = [key for key in CONTROL_FIELDS if a.get(key) is None or b.get(key) is None or a[key] != b[key]]
    for key in ("workload", "artifactDirectory"):
        if not left.get(key) or left.get(key) != right.get(key):
            mismatches.append(key)
    if a.get("backendFallback") != b.get("backendFallback"):
        mismatches.append("backendFallback")
    for key in ("runtimeIdentity", "schedulerConfiguration"):
        if not isinstance(a.get(key), dict) or not a[key] or not isinstance(b.get(key), dict) or not b[key]:
            mismatches.append(key)
    runtime_keys = ("binary_sha256", "metallib_sha256", "normalization", "renderer", "tokenizer")
    if any(not isinstance(value.get("runtimeIdentity"), dict)
           or any(not value["runtimeIdentity"].get(key) for key in runtime_keys) for value in (a, b)):
        mismatches.append("runtimeIdentity")
    return sorted(set(mismatches))


def metric(row, field):
    value = row
    for key in field.split("."):
        value = value.get(key) if isinstance(value, dict) else None
    return value if type(value) in (int, float) and math.isfinite(value) else None


def distribution(values):
    observed = [value for value in values if value is not None]
    return {"median": statistics.median(observed) if observed else None, "samples": len(observed)}


def quality_observation(left, right):
    a, b = (row["publicOutput"] if isinstance(row.get("publicOutput"), dict) else {} for row in (left, right))
    x, y = a.get("tokenIDs"), b.get("tokenIDs")
    available = isinstance(x, list) and isinstance(y, list)
    divergence = None
    if available and x != y:
        index = next((i for i, (v, w) in enumerate(zip(x, y)) if v != w), min(len(x), len(y)))
        divergence = {"index": index, "nativeToken": x[index] if index < len(x) else None,
                      "candidateToken": y[index] if index < len(y) else None}
    return {"tokenIDsEqual": x == y if available else None, "firstDivergence": divergence,
            "nativeContainsExpectedMarker": a.get("containsExpectedMarker"),
            "candidateContainsExpectedMarker": b.get("containsExpectedMarker")}


def row_index(report):
    indexed = defaultdict(list)
    for row in report["benchmark"]["rows"]:
        if isinstance(row, dict) and isinstance(row.get("promptSHA256"), str) and row["promptSHA256"]:
            key = (row.get("cell"), row.get("pair"), row.get("role"), row["promptSHA256"])
            indexed[key].append(row)
    return {key: rows[0] for key, rows in indexed.items() if len(rows) == 1}


def compare_reports(native, candidate):
    result = dict(nativeProfile=NATIVE, candidateProfile=candidate["profile"], step=candidate["step"])
    left, right = native["report"], candidate["report"]
    mismatch = control_mismatches(left, right)
    if any(type(report.get("donationControlVersion")) is not int or report["donationControlVersion"] != 1
           for report in (left, right)):
        mismatch.append("donationControlVersion")
    if left.get("warmupIterations") != right.get("warmupIterations"):
        mismatch.append("warmupIterations")
    if candidate["profile"].startswith("native-live_"):
        for key in ("liveKVQuantization", "executionStorage"):
            if left["benchmark"].get(key) is None or left["benchmark"].get(key) != right["benchmark"].get(key):
                mismatch.append(key)
    if mismatch:
        return dict(result, status="incompatible_controls", mismatches=sorted(set(mismatch)))
    a, b = row_index(left), row_index(right)
    roles = defaultdict(list)
    for key in a.keys() & b.keys():
        x, y = a[key], b[key]
        ratios = {}
        for field in METRICS:
            denominator, numerator = metric(x, field), metric(y, field)
            ratios[field] = numerator / denominator if (
                denominator is not None and denominator > 0 and numerator is not None) else None
        roles[key[2]].append(dict(cell=key[0], pair=key[1], promptSHA256=key[3],
                                 candidateOverNative=ratios, qualityObservation=quality_observation(x, y)))
    summaries = []
    for role, pairs in sorted(roles.items()):
        pairs.sort(key=lambda pair: (pair["cell"], pair["pair"], pair["promptSHA256"]))
        summaries.append(dict(role=role, pairs=pairs, medianCandidateOverNative={
            field: distribution(pair["candidateOverNative"][field] for pair in pairs) for field in METRICS}))
    matched = sum(len(pairs) for pairs in roles.values())
    return dict(result, status="paired" if matched else "no_matching_rows", roles=summaries,
                unpairedNativeRows=len(left["benchmark"]["rows"]) - matched,
                unpairedCandidateRows=len(right["benchmark"]["rows"]) - matched)


def summarize(records):
    accepted = [record for record in records if record.get("status") == "complete"
                and isinstance(record.get("report"), dict) and record["report"].get("complete") is True
                and record["report"].get("failure") is None
                and type(record["report"].get("donationControlVersion")) is int
                and record["report"]["donationControlVersion"] == 1]
    groups = defaultdict(list)
    for record in accepted:
        for row in record["report"]["benchmark"]["rows"]:
            groups[(record["profile"], record["step"], record["phase"], row["role"])].append(row)
    medians = [dict(profile=profile, step=step, phase=phase, role=role, rows=len(rows), metrics={
        field: distribution(metric(row, field) for row in rows) for field in METRICS})
        for (profile, step, phase, role), rows in sorted(groups.items())]
    by_run = {(record["profile"], record["step"]): record for record in accepted}
    comparisons = []
    for record in records:
        if record["profile"] == NATIVE:
            continue
        native = by_run.get((NATIVE, record["step"]))
        if native is not None and (record["profile"], record["step"]) in by_run:
            comparisons.append(compare_reports(native, record))
        else:
            comparisons.append(dict(nativeProfile=NATIVE, candidateProfile=record["profile"],
                                    step=record["step"], status="complete_reports_unavailable"))
    # Failed processes may have written plausible partial rows. Never expose them as results.
    runs = [record if any(record is item for item in accepted)
            else {key: value for key, value in record.items() if key != "report"}
            for record in records]
    return dict(schemaVersion=1, profileOrder=list(dict.fromkeys(record["profile"] for record in records)),
                 runs=runs, roleMedians=medians, pairedComparisons=comparisons,
                 interpretation="Observed medians and candidate/native ratios only. Encrypted disk writes are not "
                 "RAM compression credit; memory is engine-queue backend state at prefill completion before "
                 "detokenization and retirement, not process peak or total memory. TTFT includes the queue callback "
                 "overhead. Token/marker differences are "
                "quality observations, not quality pass/fail. No performance preservation claim or acceptance threshold.")
