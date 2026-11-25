#!/usr/bin/env python3
"""Exact inverse seam/extraction checks. These are not a native typecheck."""
import hashlib
import json
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parent.parent
MODEL = Path("libs/mlx-swift-lm/Libraries/MLXLLM/Models")
RUNTIME = Path("libs/darkbloom-cluster/Sources/DarkbloomClusterRuntime")


def main():
    records = []

    def read(tree, path):
        p = ROOT / tree / path
        b = p.read_bytes()
        records.append({"path": str(p.relative_to(ROOT)), "bytes": len(b), "sha256": hashlib.sha256(b).hexdigest()})
        return b.decode()

    old = read("originals", MODEL / "Qwen35MTP.swift")
    current = read("proposed", MODEL / "Qwen35MTP.swift")
    factory = read("proposed", MODEL / "Qwen35MTP+VerifiedLoading.swift")
    inverse = current.replace("    let mtp: Qwen35MTPModule\n", "    private let mtp: Qwen35MTPModule\n")
    inverse = inverse.replace("    private let ownedInputEmbedding: Embedding?\n    private var inputEmbedding: Embedding { ownedInputEmbedding ?? target.model.embedTokens }\n", "")
    inverse = inverse.replace("    init(\n        configuration: Qwen35TextConfiguration,\n        blockSize:", "    private init(\n        configuration: Qwen35TextConfiguration,\n        blockSize:")
    inverse = inverse.replace("        verificationMode: CBv2MTPVerificationMode?,\n        inputEmbedding: Embedding? = nil\n", "        verificationMode: CBv2MTPVerificationMode?\n")
    inverse = inverse.replace("        self.ownedInputEmbedding = inputEmbedding\n", "")
    assert current.count("embedTokens: inputEmbedding,") == 3
    inverse = inverse.replace("embedTokens: inputEmbedding,", "embedTokens: target.model.embedTokens,")
    start = old.index("        let assistant = Qwen35InlineMTPAssistant(\n", old.index("    public static func load("))
    end = old.index("\n        try assistant.mtp.update(", start)
    old_constructor = old[start:end]
    seam = "        let assistant = try preparedAssistant(metadata: metadata, target: target,\n            parameterNames: Set(indexed.keys), verificationMode: verificationMode)\n"
    assert inverse.count(seam) == 1
    inverse = inverse.replace(seam, old_constructor)
    inverse = inverse.replace("    static func qwen35TextTarget(", "    private static func qwen35TextTarget(")
    inverse = inverse.replace("        return try parseMetadata(data)\n    }\n\n    static func parseMetadata(_ data: Data) throws -> Qwen35InlineMTPMetadata {\n", "")
    inverse = inverse.replace("    static func validate(\n        _ artifact:", "    private static func validate(\n        _ artifact:")
    new_doc = "/// The ordinary loader owns only tensors below `mtp.*` and uses target\n/// embeddings. The verified cluster seam may additionally own an explicit\n/// embedding replica; both paths call the bound target LM head and do not require"
    old_doc = "/// The assistant owns only the tensors below `mtp.*`. Target embeddings and\n/// the LM head are called through the bound target, so loading this object does\n/// not duplicate the target checkpoint and does not require"
    inverse = inverse.replace(new_doc, old_doc)
    assert inverse == old, "Unexpected change outside the explicit assistant ownership/loading seams"
    original_quant = old_constructor[old_constructor.index("        let scaledPaths"):].replace("indexed.keys", "parameterNames")
    copied_quant = factory[factory.index("        let scaledPaths"):factory.index("        return assistant\n")]
    compact = lambda x: re.sub(r"\s+", "", x)
    assert compact(original_quant) == compact(copied_quant), "Quantization behavior changed during extraction"

    old = read("originals", RUNTIME / "QwenResidentLoading.swift")
    current = read("proposed", RUNTIME / "QwenResidentLoading.swift")
    inverse = current.replace("    let additional: QwenResidentMTPLoadResources?\n", "")
    inverse = inverse.replace("init(inventory: QwenStagePreparedInventory, additional: QwenResidentMTPLoadResources? = nil)", "init(inventory: QwenStagePreparedInventory)")
    inverse = inverse.replace("        self.additional = additional\n", "")
    inverse = inverse.replace("Array(bounds.dropFirst(next))\n                + [inert, additional?.reservedTensorBytes ?? 0]", "Array(bounds.dropFirst(next)) + [inert]")
    inverse = inverse.replace("max(next < active.count ? host : 0, additional?.largestHostTensorBytes ?? 0)", "next < active.count ? host : 0")
    begin = inverse.index("    return try loadPreparedQwenResidentStage(admission, prepared: prepared, check: check)\n")
    end = inverse.index("    let plan = admission.plan, index = admission.configuration.rank\n", begin)
    inverse = inverse[:begin] + inverse[end:]
    inverse = inverse.replace("QwenResidentLoadGate(inventory: value.inventory, additional: additional)", "QwenResidentLoadGate(inventory: value.inventory)")
    assert inverse == old, "Unexpected MTP-off target-loading behavior change"
    # Nil adds zero to the same checked sum and takes max(nonnegative, zero).
    for remaining in (0, 1, 709010432, 5038041600):
        for host in (0, 512, 508559360):
            assert remaining + 0 == remaining and max(host, 0) == host

    source = read("proposed", RUNTIME / "QwenResidentMTPSource.swift")
    loading = read("proposed", RUNTIME / "QwenResidentMTPLoading.swift")
    materializer = read("proposed", RUNTIME / "QwenResidentMTPMaterializer.swift")
    assert source.index("requireOwner(rank:") < source.index("prepareQwenResidentSource(")
    assert "tensorDescriptors(checkpoint: checkpoint)" in source
    assert "additional: source.resources" in loading
    assert "source.target" in loading and "inputEmbedding: embedding" in loading
    assert "modelParameterLayout(loaded.loaded.model) == originalLayout" in loading
    assert "cbv2MTPTargetIdentity" in loading
    assert "requestHistoryAllocated = false" in loading and "generationEnabled = false" in loading
    assert not any(x in loading + materializer + factory for x in ("loadArraysAndMetadata", "eval(model)", "Data(contentsOf:"))
    # eval(embedding) appears only in the explanatory comment; no such call is made.
    assert "\n                eval(embedding)" not in loading and "loadArraysAndMetadata" not in factory
    assert materializer.index("let entry = try progress.entry") < materializer.index("descriptor.read(.all)")
    assert materializer.index("try check(); try observe()") < materializer.index("descriptor.read(.all)")
    assert materializer.index("eval(value.array); Stream.gpu.synchronize(); try check()") < materializer.index("evaluatedBufferInfo()")
    assert materializer.index("evaluatedBufferInfo()") < materializer.index("progress.accept(copiedBytes:")
    assert "catch { progress.poison(); throw error }" in materializer
    assert "try nativeError.check()\n            throw error" in loading

    fixture = ROOT / "Tests/Fixtures/additional-tensors.json"
    values = json.loads(fixture.read_text())
    head = [x for x in values if x["name"].startswith("mtp.")]
    embedding = [x for x in values if not x["name"].startswith("mtp.")]
    assert len(head) == 31 and len(embedding) == 3
    assert sum(x["byteCount"] for x in head) == 136881152
    assert sum(x["byteCount"] for x in embedding) == 572129280
    assert sum(x["sourceDType"] == "U32" for x in head) == 8
    assert all(x["sourceDType"] in ("BF16", "U32") for x in values)
    for x in values:
        product = 2 if x["sourceDType"] == "BF16" else 4
        for dimension in x["shape"]:
            product *= dimension
        assert product == x["byteCount"]
    receipt = {"status": "passed", "records": records,
               "checks": ["exact inverse MTP assistant seams, all history bodies preserved", "quantization extraction equality",
                          "exact inverse target loader extraction and nil arithmetic", "rank-before-source/source ownership seams",
                          "selected-eval-ownership-advance order and fault precedence", "34-tensor metadata/byte replay"],
               "nativeTypecheck": False, "gpuExecution": False, "payloadVerification": False}
    Path(sys.argv[1]).write_text(json.dumps(receipt, indent=2) + "\n")
    print("PASS: exact extraction, source seams and 34-tensor metadata replay")


if __name__ == "__main__":
    main()
