#!/usr/bin/env python3
"""Replay pinned metadata arithmetic only. Never opens a weight payload."""
import argparse
import hashlib
import json
import os
import stat
from pathlib import Path

PINS = {
    "config.json": "4691da94a1b4ef415aad112ec46abebd33f8a41ad07380e486c0526eb945c1ff",
    "manifest.json": "d1239a5bc6d26d5ce4bf87f22270e3a703f4942e3d0d779948b4f65410df6dcc",
    "weight-layout.json": "2e03d0192ebb5d392c487582a3c4d1d8466fbf483c8d18bee4f9cb298997070b",
}
GIB = 1 << 30
SCRATCH = (8 << 20) + 16_384


def metadata(directory, name):
    fd = os.open(str(directory / name), os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        before = os.fstat(fd)
        assert stat.S_ISREG(before.st_mode) and 0 < before.st_size <= 1_048_576
        data = bytearray()
        while len(data) <= before.st_size:
            piece = os.read(fd, min(65_536, before.st_size + 1 - len(data)))
            if not piece:
                break
            data.extend(piece)
        after = os.fstat(fd)
        assert (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns,
                before.st_ctime_ns) == (after.st_dev, after.st_ino, after.st_size,
                                      after.st_mtime_ns, after.st_ctime_ns)
        assert len(data) == before.st_size and hashlib.sha256(data).hexdigest() == PINS[name]
        return json.loads(data)
    finally:
        os.close(fd)


def state_budget(g, capacity):
    full = g["num_hidden_layers"] // g["full_attention_interval"]
    recurrent = g["num_hidden_layers"] - full
    channels = 2 * g["linear_num_key_heads"] * g["linear_key_head_dim"]
    channels += g["linear_num_value_heads"] * g["linear_value_head_dim"]
    conv = 4 * (g["linear_conv_kernel_dim"] - 1) * channels
    ssm = 4 * g["linear_num_value_heads"] * g["linear_value_head_dim"] * g["linear_key_head_dim"]
    kv = 2 * 4 * capacity * g["num_key_value_heads"] * g["head_dim"]
    boundary = 512 * g["hidden_size"] * 4
    terms = {
        "maximumTokens": capacity, "chunkSize": 512,
        "attentionLayers": full, "recurrentLayers": recurrent,
        "convolutionBytesPerLayer": conv, "ssmBytesPerLayer": ssm,
        "kvCapacityBytesPerAttentionLayer": kv, "boundaryBytes": boundary,
        "threeRecurrentGenerationsBytes": 3 * recurrent * (conv + ssm),
        "allKVCapacityAndOffsetsBytes": full * (kv + 4),
        "largestSingleHostStateComponentBytes": max(conv, ssm, kv // 2),
        "twoBoundaryArraysBytes": 2 * boundary,
    }
    terms["conservativeStateAndBoundaryBytes"] = sum(terms[k] for k in (
        "threeRecurrentGenerationsBytes", "allKVCapacityAndOffsetsBytes",
        "largestSingleHostStateComponentBytes", "twoBoundaryArraysBytes"))
    return terms


def owner(name, cut):
    if name.startswith("language_model.model.layers."):
        return 0 if int(name.split(".")[3]) < cut else 1
    if name.startswith("language_model.model.embed_tokens."):
        return 0
    assert name == "language_model.model.norm.weight" or name.startswith("language_model.lm_head.")
    return 1


def analyze(directory):
    config, manifest, layout = (metadata(directory, n) for n in PINS)
    g = config["text_config"]
    tensors = {n: t for n, t in layout["tensors"].items() if n.startswith("language_model.")}
    identities = [n + "|" + t["dtype"] + "|" + ",".join(map(str, t["shape"])) + "|" + str(t["bytes"])
                  for n, t in sorted(tensors.items())]
    inventory = hashlib.sha256("\n".join(identities).encode()).hexdigest()
    assert inventory == "ebe2ded36d62a6f83bfa1c1b69951a8e24e9e63094745eb60c4bb353c8951624"
    assert len(tensors) == 1847 and sum(t["bytes"] for t in tensors.values()) == 15_132_802_048
    assert max(t["bytes"] for t in tensors.values()) == 635_699_200
    legacy, generation = state_budget(g, 8193), state_budget(g, 8320)
    assert legacy["conservativeStateAndBoundaryBytes"] == 1_599_082_560
    assert generation["conservativeStateAndBoundaryBytes"] == 1_616_248_896
    cuts = []
    for cut in range(4, 64, 4):
        ranks = []
        for rank in (0, 1):
            selected = {n: t for n, t in tensors.items() if owner(n, cut) == rank}
            active = sum(t["bytes"] for t in selected.values())
            host = max(t["bytes"] for t in selected.values())
            inert = (2 if rank == 0 else 1) * g["hidden_size"] * 2
            fusion = sum(t["bytes"] for n, t in selected.items() if ".linear_attn." in n and
                         n.split(".")[-2] in ("in_proj_qkv", "in_proj_z", "in_proj_b", "in_proj_a"))
            request = generation["conservativeStateAndBoundaryBytes"] + fusion
            ranks.append({"rank": rank, "sourceLayers": [0, cut] if rank == 0 else [cut, 64],
                          "tensorCount": len(selected), "selectedBytes": active,
                          "inertBytes": inert, "largestHostTensorBytes": host,
                          "fusionLogicalBytes": fusion,
                          "initialFreeLowerBound": max(6 * GIB, active + inert + 2 * host + SCRATCH + 4 * GIB),
                          "initialAllocatorLowerBoundExcludingExistingActiveAndCache": active + inert + host + 2 * GIB,
                          "postLoadFreeLowerBoundForMaximumRequest": max(6 * GIB, request + 4 * GIB),
                          "maximumRequestLogicalAllowance": request})
        assert sum(r["tensorCount"] for r in ranks) == 1847
        assert sum(r["selectedBytes"] for r in ranks) == 15_132_802_048
        cuts.append({"cut": cut, "structuralOnly": True, "ranks": ranks})
    return {"schema": "qwen27b_metadata_mapping_v1", "metadataPins": PINS,
            "publicModelID": manifest["model_id"], "runtimeModelID": "registered_qwen38_27b",
            "artifactAggregateSHA256": manifest["aggregate_sha256"],
            "manifestBytes": manifest["total_size_bytes"], "canonicalInventorySHA256": inventory,
            "canonicalTensorCount": len(tensors), "canonicalSourceBytes": 15_132_802_048,
            "namedState8193": legacy, "namedState8320": generation,
            "bf16BoundaryBytes": 512 * g["hidden_size"] * 2,
            "maximumOutputTokens": 128, "completeFrameCount": 16 + 127,
            "finalCommittedFrontierWithoutEarlyStop": 8192 + 127,
            "finalStateComponentCount": 16 * 3 + 48 * 2,
            "scratchPolicyBoundBytes": SCRATCH, "cuts": cuts,
            "actualAllocatorRoundingKnown": False, "wholeProcessBound": False,
            "payloadReadOrReverified": False, "nativeExecution": False,
            "providerEligibilityEstablished": False, "numericalQualification": False,
            "scope": "Retained header metadata arithmetic; structural cuts are not advertised or admitted runtime plans."}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model-directory", type=Path, default=Path("/Users/developer/DarkbloomDev/models/Qwen3.8-27B"))
    args = parser.parse_args()
    print(json.dumps(analyze(args.model_directory), sort_keys=True, indent=2))
