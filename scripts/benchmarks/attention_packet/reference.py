"""Independent CPU FP32 attention and descriptive error statistics, without gates."""

import math
import platform
import sys

import numpy as np

from .native import rounded


def nonfinite(values):
    return {"nan": int(np.count_nonzero(np.isnan(values))),
            "positiveInfinity": int(np.count_nonzero(np.isposinf(values))),
            "negativeInfinity": int(np.count_nonzero(np.isneginf(values)))}


def statistics(actual, reference):
    counts = {"actual": nonfinite(actual), "reference": nonfinite(reference)}
    if not np.all(np.isfinite(actual)) or not np.all(np.isfinite(reference)):
        return {"linf": None, "rmse": None, "relativeL2": None,
                "undefinedReason": "nonfinite values", "nonfinite": counts}
    # Error aggregation uses FP64; the attention operator itself stays FP32.
    difference = actual.astype(np.float64) - reference.astype(np.float64)
    numerator = float(np.sum(difference * difference, dtype=np.float64))
    reference64 = reference.astype(np.float64)
    denominator = float(np.sum(reference64 * reference64, dtype=np.float64))
    relative = math.sqrt(numerator / denominator) if denominator else (0.0 if not numerator else None)
    return {"linf": float(np.max(np.abs(difference))), "rmse": math.sqrt(numerator / difference.size),
            "relativeL2": relative,
            "undefinedReason": "zero reference norm with nonzero error" if relative is None else None,
            "nonfinite": counts}


def compare(actual, reference):
    return {"global": statistics(actual, reference),
            "perHead": [{"queryHead": head, **statistics(actual[0, head], reference[0, head])}
                        for head in range(actual.shape[1])]}


def attention(queries, keys, values, scale):
    """No repeated KV tensor: each query head addresses its own GQA KV head."""
    qh, kh = queries.shape[1], keys.shape[1]
    group = qh // kh
    output = np.empty(queries.shape, dtype=np.float32)
    intermediates = []
    with np.errstate(over="ignore", invalid="ignore", divide="ignore", under="ignore"):
        for head in range(qh):
            kv_head = head // group
            logits = np.matmul(keys[0, kv_head], queries[0, head, 0]) * np.float32(scale)
            weights = np.exp(logits - np.max(logits), dtype=np.float32)
            weights /= np.sum(weights, dtype=np.float32)
            output[0, head, 0] = np.matmul(weights, values[0, kv_head])
            intermediates.append({"queryHead": head, "kvHead": kv_head,
                                  "logits": nonfinite(logits), "weights": nonfinite(weights)})
    return output, intermediates


def last_row_consistency(packet):
    result = {}
    for stored_name, incoming_name in (("storedKeys", "incomingKeys"), ("storedValues", "incomingValues")):
        stored, incoming = packet.tensors[stored_name], packet.tensors[incoming_name]
        dtype = "<u4" if stored.descriptor["dtype"] == "float32" else "<u2"
        native_stored = np.frombuffer(stored.raw, dtype=dtype).reshape(stored.descriptor["shape"])
        native_incoming = np.frombuffer(incoming.raw, dtype=dtype).reshape(incoming.descriptor["shape"])
        unequal = native_stored[:, :, -1:, :] != native_incoming
        result[stored_name] = {"mismatchedNativeElements": int(np.count_nonzero(unequal)),
                              "comparedNativeElements": int(unequal.size)}
    return result


def analyze(packet):
    record, snapshot = packet.record, packet.snapshot
    report = {
        "schema": "darkbloom.attention-analysis.v1", "status": "inconclusive",
        "packetSHA256": packet.packet_sha256, "metadataSHA256": packet.document["metadata"]["sha256"],
        "identity": packet.document["identity"],
        "selection": {name: record[name] for name in ("requestID", "outputIndex", "phase", "storageLayerIndex",
            "modelLayerIndex", "offsetBefore", "offsetAfter", "scaleBits", "dispatch", "kernelOutputDType")},
        "sample": {name: snapshot.get(name) for name in ("forwardSucceeded", "sampleOutcome", "seedToken", "targetToken")},
        "geometry": packet.document["geometry"], "scale": packet.scale,
        "runtime": {"backend": "NumPy CPU FP32 per-query-head matmul/softmax", "numpyVersion": np.__version__,
                    "pythonVersion": platform.python_version(), "interpreter": sys.executable},
        "tensorNonfinite": {name: nonfinite(tensor.values) for name, tensor in packet.tensors.items()},
        "tensorSHA256": {name: tensor.descriptor["sha256"] for name, tensor in packet.tensors.items()},
        "inconclusiveReasons": list(packet.inconclusive_reasons),
        "limitations": ["No numerical or model-token release gate is evaluated.",
            "Each arm's gathered storage may share a layout fault with decode; full history needs an independent mirror.",
            "Different cross-backend Q/K/V can reflect earlier drift; native same-input operator replay is separate.",
            "Metadata and capture declarations do not independently prove evaluation-fence or lifetime correctness."],
    }
    if packet.inconclusive_reasons:
        return report
    rows = last_row_consistency(packet)
    report["lastRowConsistency"] = rows
    if any(value["mismatchedNativeElements"] for value in rows.values()):
        report["inconclusiveReasons"].append("stored last row differs bitwise from selected incoming K/V")
    q, k, v, actual = (packet.tensors[name].values for name in ("queries", "storedKeys", "storedValues", "output"))
    if any(not np.all(np.isfinite(value)) for value in (q, k, v)):
        report["inconclusiveReasons"].append("nonfinite original Q or stored K/V")
        return report
    reference, stages = attention(q, k, v, packet.scale)
    report["originalQueryReference"] = {"comparison": compare(actual, reference), "intermediateNonfinite": stages}
    output_dtype = packet.tensors["output"].descriptor["dtype"]
    report["referenceRoundedToOutputDType"] = {
        "dtype": output_dtype, "comparison": compare(actual, rounded(reference, output_dtype))}
    q_dtype, kv_dtype = (packet.tensors[name].descriptor["dtype"] for name in ("queries", "storedKeys"))
    if q_dtype == "float32" and kv_dtype in {"float16", "bfloat16"}:
        narrowed_q = rounded(q, kv_dtype)
        narrowed, stages = attention(narrowed_q, k, v, packet.scale)
        report["narrowedQueryCounterfactual"] = {
            "cast": "float32 -> " + kv_dtype + " -> float32", "comparison": compare(actual, narrowed),
            "differenceFromOriginalReference": compare(narrowed, reference),
            "queryRoundingDifference": compare(narrowed_q, q), "intermediateNonfinite": stages}
    else:
        report["narrowedQueryCounterfactual"] = None
    if not np.all(np.isfinite(actual)) or not np.all(np.isfinite(reference)):
        report["inconclusiveReasons"].append("nonfinite output or FP32 reference")
    report["status"] = "analyzed" if not report["inconclusiveReasons"] else "inconclusive"
    return report
