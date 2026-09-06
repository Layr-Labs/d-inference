"""Small synthetic packets, independent of any model or native runtime."""

import hashlib
import json
from pathlib import Path
import struct

import numpy as np

from attention_packet.native import decode, encode, packed_strides


def oracle(q, k, v, scale, *, head_map=None, drop_last=False, transpose_keys=False):
    """Test-only FP64 formula; deliberately separate from the FP32 implementation."""
    result = np.empty(q.shape, dtype=np.float32)
    for head in range(q.shape[1]):
        kh = head_map(head) if head_map else head // (q.shape[1] // k.shape[1])
        keys = k[0, kh].astype(np.float64)
        values = v[0, kh].astype(np.float64)
        if transpose_keys:
            keys = keys.T
        if drop_last:
            keys, values = keys[:-1], values[:-1]
        logits = keys @ q[0, head, 0].astype(np.float64) * float(scale)
        weights = np.exp(logits - np.max(logits))
        result[0, head, 0] = (weights / weights.sum()) @ values
    return result


def write_json(path, value):
    raw = (json.dumps(value, indent=2) + "\n").encode()
    path.write_bytes(raw)
    return raw


def observed(descriptor):
    return {"dtype": descriptor["dtype"], "shape": descriptor["shape"],
            "graphConstructionStrides": descriptor["packedStrides"]}


class Fixture:
    def __init__(self, root, q_dtype="float32", kv_dtype="bfloat16", output_dtype="float32",
                 heads=16, kv_heads=2, length=16, dimension=16, uniform=False):
        self.root = Path(root)
        self.root.mkdir(parents=True, exist_ok=True)
        rng = np.random.default_rng(11346)
        q = rng.normal(size=(1, heads, 1, dimension)).astype(np.float32)
        k = rng.normal(size=(1, kv_heads, length, dimension)).astype(np.float32)
        v = rng.normal(size=k.shape).astype(np.float32)
        if uniform:
            q.fill(0)
        v[:, :, -1, :] += 12
        self.descriptors, self.values = {}, {}
        for name, values, dtype in (("queries", q, q_dtype), ("storedKeys", k, kv_dtype),
                                   ("storedValues", v, kv_dtype)):
            self.set_tensor(name, values, dtype)
        self.scale = np.float32(1 / np.sqrt(dimension))
        actual = oracle(self.values["queries"], self.values["storedKeys"], self.values["storedValues"], self.scale)
        self.set_tensor("incomingKeys", self.values["storedKeys"][:, :, -1:, :], kv_dtype)
        self.set_tensor("incomingValues", self.values["storedValues"][:, :, -1:, :], kv_dtype)
        self.set_tensor("output", actual, output_dtype)
        self.record = {"requestID": 2, "outputIndex": 62, "phase": "chained_decode",
            "batchIndex": 0, "batchSize": 1, "inputWidth": 1, "storageLayerIndex": 0, "modelLayerIndex": 3,
            "offsetBefore": length - 1, "offsetAfter": length,
            "scaleBits": struct.unpack("<I", struct.pack("<f", self.scale))[0],
            "queries": observed(self.descriptors["queries"]),
            "incomingKeys": observed(self.descriptors["incomingKeys"]),
            "incomingValues": observed(self.descriptors["incomingValues"]),
            "output": observed(self.descriptors["output"]),
            "storage": {"segment_0_keys_and_values": observed(self.descriptors["storedKeys"])},
            "kernelOutputDType": kv_dtype, "dispatch": "paged_segmented_decode",
            "sinksPresent": False, "softcapPresent": False, "spansPresent": False}
        self.snapshot = {"configuration": {"requestID": 2, "outputIndex": 62, "maximumRecords": 1},
            "records": [self.record], "selectedForwards": 1, "expectedOwnerCount": 1,
            "forwardSucceeded": True, "sampleOutcome": "confirmed", "seedToken": 11346,
            "targetToken": 6829, "refusals": {}}
        self.document = {"schema": "darkbloom.attention-packet.v1", "identity": {
            "modelID": "synthetic-attention-fixture", "artifactSHA256": "a" * 64,
            "inputSHA256": "b" * 64, "backend": "paged"},
            "metadata": {}, "geometry": {"attention": "full", "isBidirectional": False,
                "sharesKV": False, "mtpEnabled": False, "visibleStart": 0, "visibleEnd": length},
            "capture": {"evaluationStatus": "completed", "tensorPayloadBytes": 0}, "tensors": self.descriptors}
        self.save()

    def set_tensor(self, name, values, dtype=None):
        dtype = dtype or self.descriptors[name]["dtype"]
        values = np.asarray(values, dtype=np.float32)
        raw = encode(values, dtype)
        self.descriptors[name] = {"file": name + ".bin", "dtype": dtype, "byteOrder": "little",
            "shape": list(values.shape), "packedStrides": packed_strides(values.shape),
            "byteCount": len(raw), "sha256": hashlib.sha256(raw).hexdigest()}
        (self.root / (name + ".bin")).write_bytes(raw)
        self.values[name] = decode(raw, dtype, values.shape)

    def save(self):
        raw = write_json(self.root / "attention-metadata.json", self.snapshot)
        self.document["metadata"] = {"file": "attention-metadata.json", "byteCount": len(raw),
            "sha256": hashlib.sha256(raw).hexdigest(), "recordIndex": 0}
        self.document["capture"]["tensorPayloadBytes"] = sum(x["byteCount"] for x in self.descriptors.values())
        write_json(self.root / "packet.json", self.document)
        return self.root / "packet.json"
