"""Validate one evaluated, native-dtype attention packet before numerical work."""

from dataclasses import dataclass
import math
from pathlib import Path
import struct

from .files import (MAX_JSON_BYTES, MAX_TENSOR_BYTES, UnsupportedPacket, digest,
                    hashed_file, integer, parse_json, read_bounded, require, sha256)
from .native import ITEM_BYTES, decode, packed_strides

TENSOR_NAMES = {"queries", "storedKeys", "storedValues", "incomingKeys", "incomingValues", "output"}
OUTCOMES = {"not_selected", "graph_constructed_unconfirmed", "forward_failed", "confirmed",
            "discarded", "retired_unconfirmed"}
DISPATCHES = {"paged": {"paged_segmented_decode", "paged_fixed_decode"},
              "contiguous": {"contiguous_sdpa"}}


@dataclass
class Tensor:
    descriptor: dict
    raw: bytes
    values: object


@dataclass
class Packet:
    document: dict
    snapshot: dict
    record: dict
    tensors: dict
    packet_sha256: str
    scale: float
    inconclusive_reasons: list


def tensor_descriptor(value):
    require(isinstance(value, dict), "invalid tensor descriptor")
    dtype = value.get("dtype")
    require(isinstance(dtype, str) and dtype in ITEM_BYTES, "unsupported tensor dtype")
    require(value.get("byteOrder") == "little", "unsupported tensor byte order")
    shape = value.get("shape")
    require(isinstance(shape, list) and len(shape) == 4, "tensor shape must be [B,H,T,D]")
    for dimension in shape:
        integer(dimension, "tensor dimension", 1, MAX_TENSOR_BYTES)
    count = math.prod(shape) * ITEM_BYTES[dtype]
    require(count <= MAX_TENSOR_BYTES, "tensor exceeds byte budget")
    require(value.get("packedStrides") == packed_strides(shape)
            and all(type(x) is int for x in value["packedStrides"]), "non-packed tensor strides")
    require(integer(value.get("byteCount"), "tensor byteCount", 1, MAX_TENSOR_BYTES) == count,
            "tensor shape/byte length mismatch")
    return count


def observed_tensor(value):
    require(isinstance(value, dict) and isinstance(value.get("dtype"), str)
            and value["dtype"] in ITEM_BYTES, "invalid observed tensor dtype")
    shape, strides = value.get("shape"), value.get("graphConstructionStrides")
    require(isinstance(shape, list) and 1 <= len(shape) <= 8, "invalid observed tensor shape")
    require(isinstance(strides, list) and len(strides) == len(shape), "invalid observed graph strides")
    for dimension in shape:
        integer(dimension, "observed tensor dimension", 1)
    for stride in strides:
        integer(stride, "observed graph stride")


def selected_record(snapshot, record_index):
    config, records = snapshot.get("configuration"), snapshot.get("records")
    require(isinstance(config, dict) and isinstance(records, list) and 1 <= len(records) <= 128,
            "invalid selected metadata snapshot")
    integer(config.get("requestID"), "configured requestID", 1, 2**64 - 1)
    integer(config.get("outputIndex"), "configured outputIndex", 1, 1_000_000)
    integer(record_index, "recordIndex", 0, 127)
    integer(snapshot.get("expectedOwnerCount"), "expectedOwnerCount", 1, 128)
    if snapshot["expectedOwnerCount"] != 1 or len(records) != 1 or record_index != 0:
        raise UnsupportedPacket("packet v1 requires exactly one owner, one record, and recordIndex zero")
    maximum_records = integer(config.get("maximumRecords"), "maximumRecords", 1, 128)
    require(len(records) <= maximum_records, "metadata record budget exceeded")
    record = records[record_index]
    require(isinstance(record, dict), "invalid selected metadata record")
    for name in ("requestID", "outputIndex"):
        require(type(record.get(name)) is int and record[name] == config[name], "selected " + name + " mismatch")
    for name in ("batchIndex", "storageLayerIndex", "modelLayerIndex", "offsetBefore", "offsetAfter"):
        integer(record.get(name), name)
    for name in ("batchSize", "inputWidth"):
        integer(record.get(name), name, 1)
    integer(snapshot.get("selectedForwards"), "selectedForwards", 0, 128)
    require(type(snapshot.get("forwardSucceeded")) is bool and isinstance(snapshot.get("sampleOutcome"), str)
            and snapshot["sampleOutcome"] in OUTCOMES,
            "invalid forward/sample outcome")
    require(isinstance(snapshot.get("refusals"), dict), "missing metadata refusals")
    for count in snapshot["refusals"].values():
        integer(count, "refusal count", 1)
    for name in ("seedToken", "targetToken"):
        if snapshot.get(name) is not None:
            integer(snapshot[name], name, 0, 2**31 - 1)
    reasons = []
    if (not snapshot["forwardSucceeded"] or snapshot["sampleOutcome"] != "confirmed"
            or snapshot["selectedForwards"] != 1 or snapshot["refusals"]
            or snapshot.get("seedToken") is None or snapshot.get("targetToken") is None):
        reasons.append("selected step is not complete and confirmed")
    return record, reasons


def validate_geometry(document, record, tensors):
    identity, geometry, capture = (document.get(key) for key in ("identity", "geometry", "capture"))
    require(isinstance(identity, dict) and isinstance(geometry, dict) and isinstance(capture, dict),
            "missing packet identity/geometry/capture")
    require(isinstance(identity.get("modelID"), str) and 0 < len(identity["modelID"]) <= 512, "invalid modelID")
    for name in ("artifactSHA256", "inputSHA256"):
        digest(identity.get(name), name)
    require(isinstance(identity.get("backend"), str) and identity["backend"] in DISPATCHES, "invalid backend identity")
    require(isinstance(record.get("kernelOutputDType"), str) and record["kernelOutputDType"] in ITEM_BYTES,
            "invalid native dispatch output dtype")
    for name in ("isBidirectional", "sharesKV", "mtpEnabled"):
        require(type(geometry.get(name)) is bool, "missing geometry flag " + name)
    for name in ("sinksPresent", "softcapPresent", "spansPresent"):
        require(type(record.get(name)) is bool, "missing metadata flag " + name)
    supported = (geometry.get("attention") == "full"
        and not any(geometry[name] for name in ("isBidirectional", "sharesKV", "mtpEnabled"))
        and not any(record[name] for name in ("sinksPresent", "softcapPresent", "spansPresent"))
        and record["batchSize"] == 1 and record["batchIndex"] == 0 and record["inputWidth"] == 1
        and isinstance(record.get("phase"), str) and record["phase"] in {"decode", "chained_decode"}
        and isinstance(record.get("dispatch"), str) and record["dispatch"] in DISPATCHES[identity["backend"]])
    if not supported:
        raise UnsupportedPacket("unsupported B1/full-attention/L1/phase/dispatch geometry")
    q, k, v, incoming_k, incoming_v, output = (tensors[name] for name in (
        "queries", "storedKeys", "storedValues", "incomingKeys", "incomingValues", "output"))
    _, qh, ql, dimension = q["shape"]
    _, kh, length, kd = k["shape"]
    require(qh % kh == 0 and ql == 1 and dimension == kd, "invalid Q/KV GQA geometry")
    require(q["shape"] == [1, qh, 1, dimension] and output["shape"] == q["shape"], "invalid Q/output geometry")
    require(k["shape"] == [1, kh, length, dimension] and v["shape"] == k["shape"], "invalid stored K/V geometry")
    require(incoming_k["shape"] == [1, kh, 1, dimension] and incoming_v["shape"] == incoming_k["shape"],
            "invalid incoming K/V geometry")
    require(len({x["dtype"] for x in (k, v, incoming_k, incoming_v)}) == 1, "stored/incoming KV dtype conversion unsupported")
    require(integer(geometry.get("visibleStart"), "visibleStart") == 0, "full attention must include absolute history origin")
    require(integer(geometry.get("visibleEnd"), "visibleEnd", 1) == record["offsetAfter"] == length
            and record["offsetBefore"] + 1 == record["offsetAfter"], "visible range/last token mismatch")
    for name in ("queries", "incomingKeys", "incomingValues", "output"):
        observed_tensor(record.get(name))
        require(all(record[name][key] == tensors[name][key] for key in ("dtype", "shape")),
                "captured tensor differs from observed " + name)
    storage = record.get("storage")
    require(isinstance(storage, dict) and 0 < len(storage) <= 64, "missing native storage metadata")
    for value in storage.values():
        observed_tensor(value)
        require(value["dtype"] == k["dtype"], "stored dtype differs from observed native storage")
    bits = integer(record.get("scaleBits"), "scaleBits", 0, 2**32 - 1)
    scale = struct.unpack("<f", struct.pack("<I", bits))[0]
    require(math.isfinite(scale) and scale > 0, "scaleBits must encode positive finite FP32")
    # Avoid pathological CPU work even when an unusual GQA ratio fits raw bytes.
    if qh > 256 or dimension > 1024 or 2 * qh * length * dimension > 100_000_000:
        raise UnsupportedPacket("packet exceeds bounded CPU reference geometry")
    return scale


def load_packet(path):
    path = Path(path).resolve(strict=True)
    raw_document = read_bounded(path, MAX_JSON_BYTES)
    document = parse_json(raw_document)
    require(document.get("schema") == "darkbloom.attention-packet.v1", "unsupported packet schema")
    root, used = path.parent, {path}
    metadata = document.get("metadata")
    metadata_raw = hashed_file(root, metadata, used, MAX_JSON_BYTES)
    snapshot = parse_json(metadata_raw)
    record, reasons = selected_record(snapshot, metadata.get("recordIndex"))
    descriptors = document.get("tensors")
    require(isinstance(descriptors, dict) and set(descriptors) == TENSOR_NAMES, "packet requires exactly six tensors")
    total = sum(tensor_descriptor(value) for value in descriptors.values())
    require(total <= MAX_TENSOR_BYTES, "total tensor payload exceeds 32 MiB")
    scale = validate_geometry(document, record, descriptors)
    capture = document["capture"]
    require(integer(capture.get("tensorPayloadBytes"), "tensorPayloadBytes", 1, MAX_TENSOR_BYTES) == total,
            "declared total tensor bytes mismatch")
    require(isinstance(capture.get("evaluationStatus"), str)
            and capture["evaluationStatus"] in {"completed", "failed", "not_evaluated"}, "invalid evaluation status")
    if capture["evaluationStatus"] != "completed":
        reasons.append("tensor evaluation not completed")
    native_bytes = {name: hashed_file(root, descriptor, used, MAX_TENSOR_BYTES)
                    for name, descriptor in descriptors.items()}
    tensors = {name: Tensor(descriptor, native_bytes[name],
                           decode(native_bytes[name], descriptor["dtype"], descriptor["shape"]))
               for name, descriptor in descriptors.items()}
    return Packet(document, snapshot, record, tensors, sha256(raw_document), scale, reasons)
