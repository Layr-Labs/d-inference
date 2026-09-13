"""Admit a packet once and stage unchanged native bytes for the Swift probe."""
import json
from pathlib import Path

import numpy as np

from attention_packet.files import require, sha256
from attention_packet.native import ITEM_BYTES
from attention_packet.packet import load_packet
from attention_packet.reference import last_row_consistency

ARMS = ("nativeSDPA", "pagedFixed", "pagedSegmented")
DISPATCH = {"nativeSDPA": "contiguous_sdpa", "pagedFixed": "paged_fixed_decode",
            "pagedSegmented": "paged_segmented_decode"}


def geometry(packet):
    q = packet.tensors["queries"].descriptor
    k = packet.tensors["storedKeys"].descriptor
    qh, kh, length, dimension = q["shape"][1], k["shape"][1], k["shape"][2], q["shape"][3]
    require(dimension in {64, 128, 256, 512} and length <= 32768,
            "unsupported paged replay geometry")
    total = sum(len(t.raw) for n, t in packet.tensors.items() if n != "output")
    page_bytes = 2 * kh * 16 * dimension * ITEM_BYTES[k["dtype"]]
    pool_bytes = max(8 << 20, ((length + 15) // 16 + 64) * page_bytes * 2)
    bound = total * 6 + pool_bytes * 2 + (16 << 20)
    require(bound <= 256 << 20, "replay allocation plan exceeds 256 MiB")
    return {"queryHeads": qh, "kvHeads": kh, "length": length, "headDim": dimension,
            "inputBytes": total, "pageSize": 16, "poolBudgetBytes": pool_bytes,
            "segmentTargetBytes": page_bytes * 257, "allocationBoundBytes": bound}


def prepare(packet_path, output):
    packet = load_packet(packet_path)
    require(not packet.inconclusive_reasons, "replay requires a confirmed completed packet")
    require(all(np.all(np.isfinite(t.values)) for t in packet.tensors.values()),
            "nonfinite packet cannot enter operator replay")
    require(not any(x["mismatchedNativeElements"] for x in last_row_consistency(packet).values()),
            "stored tail differs from incoming write")
    allocation = geometry(packet)
    descriptors = {name: {**tensor.descriptor, "file": name + ".bin"}
                   for name, tensor in packet.tensors.items()}
    transfer = {"schema": "darkbloom.attention-replay-input.v1", "packetSHA256": packet.packet_sha256,
        "metadataSHA256": packet.document["metadata"]["sha256"], "identity": packet.document["identity"],
        "selection": {name: packet.record[name] for name in ("requestID", "outputIndex", "phase",
            "storageLayerIndex", "modelLayerIndex", "offsetBefore", "offsetAfter", "dispatch")},
        "sampleOutcome": packet.snapshot["sampleOutcome"], "scaleBits": packet.record["scaleBits"],
        "geometry": allocation, "tensors": descriptors}
    output = Path(output)
    output.mkdir()  # A new owned root; never overwrite earlier replay evidence.
    for name, tensor in packet.tensors.items():
        (output / descriptors[name]["file"]).write_bytes(tensor.raw)
    raw = (json.dumps(transfer, indent=2) + "\n").encode()
    (output / "input.json").write_bytes(raw)
    return packet, transfer, sha256(raw)
