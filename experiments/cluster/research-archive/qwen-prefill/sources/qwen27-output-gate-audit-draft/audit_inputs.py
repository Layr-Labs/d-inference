#!/usr/bin/env python3
"""Read retained metadata and source text only; never import an inference library."""
from pathlib import Path
import hashlib
import json

HERE = Path(__file__).resolve().parent
RESEARCH = HERE.parent
REPO = RESEARCH.parent / "d-inference"
MODEL = RESEARCH.parent / "models/Qwen3.8-27B"
LM = REPO / "libs/mlx-swift-lm/Libraries/MLXLLM/Models"
CLUSTER = REPO / "experiments/cluster/inference/Sources/ClusterInference"


def sha(data):
    return hashlib.sha256(data).hexdigest()


def pin(path):
    data = path.read_bytes()
    return {"path": str(path), "byteCount": len(data), "sha256": sha(data)}


def main():
    paths = [MODEL / "config.json", MODEL / "manifest.json", MODEL / "weight-layout.json",
        RESEARCH / "catalog-2026-09-13.json", RESEARCH / "local-registered-model-inventory-20260913.json",
        RESEARCH / "qwen38-output-gate-and-eligibility-audit-20260913.json",
        LM / "Qwen35.swift", LM / "Qwen3Next.swift", CLUSTER / "QwenLayerStageMetadata.swift",
        CLUSTER / "PreparedQwenLayerSource.swift", CLUSTER / "QwenRegistered9BLongPrefillAdmission.swift",
        REPO / "provider-swift/Sources/ProviderCore/Models/ModelRuntimeRequirements.swift",
        REPO / "provider-swift/Sources/ProviderCore/ProviderLoop+ModelLoading.swift",
        REPO / "provider-swift/Sources/ProviderCore/Server/StandaloneServer.swift",
        REPO / "provider-swift/Sources/ProviderCore/Models/ModelDownloader.swift",
        REPO / "provider-swift/Tests/ProviderCoreTests/ModelRuntimeRequirementsTests.swift",
        REPO / "libs/mlx-swift-lm/Tests/MLXLMTests/Qwen35CBv2ConfigurationTests.swift"]
    before = [pin(p) for p in paths]
    config = json.loads((MODEL / "config.json").read_bytes())
    manifest = json.loads((MODEL / "manifest.json").read_bytes())
    config_entry = next(x for x in manifest["files"] if x["path"] == "config.json")
    assert before[0]["sha256"] == config_entry["sha256"] == "4691da94a1b4ef415aad112ec46abebd33f8a41ad07380e486c0526eb945c1ff"
    assert before[0]["byteCount"] == config_entry["size_bytes"] == 4441
    official = json.loads((HERE / "official-qwen27-config.json").read_bytes())
    assert official["text_config"] == config["text_config"]
    text = config["text_config"]
    assert (text["output_gate_type"], text["hidden_act"], text["attn_output_gate"]) == ("swish", "silu", True)
    assert (text["num_hidden_layers"], text["full_attention_interval"]) == (64, 4)
    layout = json.loads((MODEL / "weight-layout.json").read_bytes())
    assert layout["catalog_aggregate_sha256"] == manifest["aggregate_sha256"]
    assert config["quantization"] == config["quantization_config"] == {"bits": 4, "group_size": 64, "mode": "affine"}
    tensors = layout["tensors"]
    recurrent = []
    attention = []
    for layer in range(64):
        base = "language_model.model.layers.%d." % layer
        if (layer + 1) % 4:
            recurrent.append(layer)
            for suffix, shape, dtype in [
                ("in_proj_z.weight", [6144, 640], "U32"),
                ("norm.weight", [128], "BF16"),
                ("out_proj.weight", [5120, 768], "U32")]:
                entry = tensors[base + "linear_attn." + suffix]
                assert entry["shape"] == shape and entry["dtype"] == dtype
        else:
            attention.append(layer)
            entry = tensors[base + "self_attn.q_proj.weight"]
            assert entry["shape"] == [12288, 640] and entry["dtype"] == "U32"
    assert len(recurrent) == 48 and len(attention) == 16
    swift = (LM / "Qwen35.swift").read_text()
    norm = (LM / "Qwen3Next.swift").read_text()
    tf_config = (HERE / "transformers-v5.8.0-configuration_qwen3_5.py").read_text()
    tf_model = (HERE / "transformers-v5.8.0-modeling_qwen3_5.py").read_text()
    tf_activations = (HERE / "transformers-v5.8.0-activations.py").read_text()
    assert "output_gate_type" not in swift and "outputGateType" not in swift
    assert "output_gate_type" not in tf_config and "output_gate_type" not in tf_model
    assert "Qwen3NextRMSNormGated(dimensions: headVDim, eps: args.rmsNormEps)" in swift
    assert swift.count("let normedOut = norm(out, gate: z)") == 3
    assert "let g = silu(gate.asType(.float32))" in norm
    assert "return (g * x.asType(.float32)).asType(hiddenStates.dtype)" in norm
    assert "x * sigmoid(gate)" in norm and swift.count("sigmoidMultiply(output, gate)") == 2
    assert "hidden_states = hidden_states * F.silu(gate.to(torch.float32))" in tf_model
    assert "core_attn_out = self.norm(core_attn_out, z)" in tf_model
    assert "attn_output = attn_output * torch.sigmoid(gate)" in tf_model
    assert '"silu": SiLUActivation' in tf_activations and '"swish": nn.SiLU' in tf_activations
    requirements = paths[11].read_text()
    assert '"EigenLabs/Qwen3.8-27B-4bit-mtp"' in requirements
    assert ".appleM5, .mlxNAX" in requirements
    assert "if chipFamily == .m5" in requirements
    assert "required.formUnion(qwen38RequiredCapabilities)" in requirements
    assert "output_gate_type" not in requirements and "swish" not in requirements
    catalog = json.loads((RESEARCH / "catalog-2026-09-13.json").read_bytes())
    entry = next(x for x in catalog["models"] if x["id"] == manifest["model_id"])
    assert entry["aggregate_sha256"] == manifest["aggregate_sha256"]
    assert entry["required_provider_capabilities"] == ["apple_m5", "mlx_nax"]
    inventory = json.loads((RESEARCH / "local-registered-model-inventory-20260913.json").read_bytes())
    retained = next(x for x in inventory["models"] if x["model_id"] == manifest["model_id"])
    assert retained["catalog_aggregate_sha256"] == manifest["aggregate_sha256"]
    assert retained["source_text_tensor_bytes"] == 15132802048
    assert before == [pin(p) for p in paths]
    source_archive = HERE / "local-source-archive"
    source_archive.mkdir(exist_ok=True)
    for path in paths[6:]:
        (source_archive / path.name).write_bytes(path.read_bytes())
    result = {"schemaVersion": 1, "status": "passed", "scope": "Source text and retained metadata only",
        "sourceInputs": before, "inputPinsUnchanged": True,
        "registeredArtifact": {"id": manifest["model_id"], "aggregateSHA256ClaimedByManifest": manifest["aggregate_sha256"],
            "configurationSHA256": before[0]["sha256"], "configurationMatchesManifestEntry": True,
            "canonicalTextTensorBytesFromRetainedInventory": retained["source_text_tensor_bytes"]},
        "officialTextConfigurationEqual": True,
        "officialConfigRevisionVerified": "1d4bf0f2ff6012fd82039f2fa52739d0dd7c60c0",
        "catalogClaimedHubRevision": entry["metadata"]["hub_revision"],
        "catalogClaimedHubRevisionRetrieved": False,
        "transformersTag": "v5.8.0", "transformersCommit": "049d2bf1220747b6d39e2a978b9f5fe0defa1dca",
        "repositoryHEAD": "e4df336bc8399f4fd0a46d1207b594d2514f14f5",
        "mlxSwiftLMHEAD": "ce446cc5f76e013855fe0bde9002b6db1ac091b7",
        "directFieldDispatchFoundInSwiftOrTransformers": False,
        "gdGateOperatorFamilyCompatibleWithPinnedReference": True,
        "fullAttentionGateRemainsSeparateSigmoid": True,
        "retainedHeaderGatedDeltaLayerCount": len(recurrent), "retainedHeaderAttentionLayerCount": len(attention),
        "productionRequirements": entry["required_provider_capabilities"],
        "productionPolicyChanged": False, "plannerAdmissionChanged": False,
        "modelConstructedOrExecuted": False, "newWeightOrHeaderNetworkReads": False,
        "modelPayloadBytesRead": 0, "crossRuntimeNumericalParityEstablished": False}
    (HERE / "source-metadata-receipt.json").write_text(json.dumps(result, sort_keys=True, indent=2) + "\n")
    print(json.dumps({"status": "passed", "primaryTextConfigurationEqual": True,
        "sourceInputsPinned": len(paths), "recurrentHeaderShapesChecked": len(recurrent) * 3,
        "attentionHeaderShapesChecked": len(attention), "nativeExecuted": False}, sort_keys=True))


if __name__ == "__main__":
    main()
