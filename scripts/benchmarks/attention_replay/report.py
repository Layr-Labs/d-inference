"""Compare actual probe results to the original-Q CPU reference, without gates."""
from pathlib import Path

import numpy as np

from attention_packet.files import (MAX_JSON_BYTES, MAX_TENSOR_BYTES, hashed_file,
                                    integer, parse_json, payload_path, read_bounded, require)
from attention_packet.native import decode, rounded
from attention_packet.packet import tensor_descriptor
from attention_packet.reference import attention, compare
from .transfer import ARMS, DISPATCH


def collect(packet, transfer, transfer_sha256, root):
    root = Path(root).resolve(strict=True)
    q, k, v = (packet.tensors[name].values for name in ("queries", "storedKeys", "storedValues"))
    reference, stages = attention(q, k, v, packet.scale)
    results, values = {}, {}
    reasons = []
    for arm in ARMS:
        arm_root = (root / arm).resolve(strict=True)
        require(arm_root.is_relative_to(root), "replay result escapes owned root")
        used = set()
        result_path = payload_path(arm_root, "result.json", used)
        result = parse_json(read_bounded(result_path, MAX_JSON_BYTES))
        require(result.get("schema") == "darkbloom.attention-replay-result.v1"
                and result.get("inputSHA256") == transfer_sha256 and result.get("arm") == arm,
                "replay result input or arm identity mismatch")
        require(result.get("dispatch") == DISPATCH[arm], "requested replay dispatch was not observed")
        require(result.get("geometry") == transfer["geometry"] and result.get("offset") == k.shape[2],
                "replay geometry or final offset mismatch")
        kernel_dtype = packet.tensors["queries" if arm == "nativeSDPA" else "storedKeys"].descriptor["dtype"]
        require(result.get("kernelOutputDType") == kernel_dtype, "replay kernel output dtype mismatch")
        segments = integer(result.get("segmentCount"), "replay segment count", 0, 64)
        table = result.get("pageTable")
        require(isinstance(table, list), "missing replay page table")
        if arm == "nativeSDPA":
            require(segments == 0 and table == [] and result.get("partitionTokens") is None,
                    "native arm has paged geometry")
        else:
            require(len(table) == (k.shape[2] + 15) // 16, "replay page table length mismatch")
            for page in table: integer(page, "replay physical page", 1, 2**31 - 1)
            require(len(set(table)) == len(table), "replay physical pages alias")
            integer(result.get("partitionTokens"), "replay partition tokens", 1, 32768)
            require(result["partitionTokens"] in (64, 128, 256), "unsupported pinned partition rung")
            require(segments == 0 if arm == "pagedFixed" else segments >= (2 if k.shape[2] > 4096 else 1),
                    "replay segment layout mismatch")
        descriptors = result.get("tensors")
        expected = {"output"} if arm == "nativeSDPA" else {"output", "storedKeys", "storedValues"}
        require(isinstance(descriptors, dict) and set(descriptors) == expected, "incomplete replay tensor result")
        require(sum(tensor_descriptor(d) for d in descriptors.values()) <= MAX_TENSOR_BYTES,
                "replay result exceeds native byte budget")
        raw = {}
        for name, descriptor in descriptors.items():
            source = packet.tensors["queries" if name == "output" else name].descriptor
            require(descriptor["dtype"] == source["dtype"] and descriptor["shape"] == source["shape"],
                    "replay result tensor shape or dtype mismatch")
            raw[name] = hashed_file(arm_root, descriptor, used, MAX_TENSOR_BYTES)
        stored_identity = {}
        for name in expected - {"output"}:
            stored_identity[name] = raw[name] == packet.tensors[name].raw
            if not stored_identity[name]: reasons.append(arm + " full-history readback differs: " + name)
        actual = decode(raw["output"], descriptors["output"]["dtype"], q.shape)
        values[arm] = actual
        entry = {"receipt": result, "storedHistoryByteIdentity": stored_identity,
            "originalQueryReference": compare(actual, reference),
            "referenceRoundedToOutputDType": compare(actual, rounded(reference, descriptors["output"]["dtype"])),
            "capturedOutputByteIdentity": raw["output"] == packet.tensors["output"].raw}
        if not np.all(np.isfinite(actual)): reasons.append(arm + " returned nonfinite output")
        if DISPATCH[arm] == packet.record["dispatch"] and not entry["capturedOutputByteIdentity"]:
            reasons.append(arm + " does not reproduce its original captured output")
        if packet.tensors["queries"].descriptor["dtype"] == "float32" and packet.tensors["storedKeys"].descriptor["dtype"] != "float32":
            narrowed, _ = attention(rounded(q, packet.tensors["storedKeys"].descriptor["dtype"]), k, v, packet.scale)
            entry["narrowedQueryCounterfactual"] = {
                "comparison": compare(actual, narrowed), "differenceFromOriginalReference": compare(narrowed, reference)}
        results[arm] = entry
    if not np.all(np.isfinite(reference)): reasons.append("FP32 reference is nonfinite")
    return {"schema": "darkbloom.attention-replay-analysis.v1",
        "status": "inconclusive" if reasons else "analyzed", "inconclusiveReasons": reasons,
        "packetSHA256": packet.packet_sha256, "inputSHA256": transfer_sha256,
        "identity": transfer["identity"], "selection": transfer["selection"], "arms": results,
        "originalReferenceIntermediateNonfinite": stages,
        "sameInputOperatorComparisons": {a + "_versus_" + b: compare(values[a], values[b])
            for a, b in (("pagedFixed", "nativeSDPA"), ("pagedSegmented", "nativeSDPA"), ("pagedSegmented", "pagedFixed"))},
        "limitations": ["No numerical or model-token release gate is evaluated.",
            "Reconstructed packed history is not the original physical slab or strided backing layout.",
            "Replay readback proves placement of supplied bytes, not correctness of original model history.",
            "Original incoming-history mirror and cross-backend Q/K/V identity remain separate proofs."]}
