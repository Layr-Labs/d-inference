#!/usr/bin/env python3
"""Bounded source/patch checks only; never compile or execute Swift/native code."""
from pathlib import Path
import difflib
import hashlib
import json

ROOT = Path(__file__).resolve().parent
REPO = ROOT.parent.parent / "d-inference"
PREFIX = "experiments/cluster/inference/Sources/ClusterInference/"


def verify(proposed):
    old = (ROOT / "originals/QwenLongPrefillRankReadiness.swift").read_text()
    exchange = proposed["QwenLongPrefillReadinessExchange.swift"]
    old_body = old[old.index("    guard collective.size"):]
    extracted = old_body.replace(
        'let digest = sha256(Data(("qwen-profiled-prefill-readiness-v1|" + agreement.fingerprint).utf8))',
        "let digest = material().digest",
    ).replace(
        'throw ProbeError("Long ranks disagree on admitted source, input, arithmetic or scheduling before clock start")',
        "throw ProbeError(disagreementMessage)",
    ).replace(
        "return .init(agreementFingerprint: agreement.fingerprint, readinessMaterialSHA256: digest)",
        "return digest",
    )
    assert exchange[exchange.index("    guard collective.size"):] == extracted
    wrapper = proposed["QwenLongPrefillRankReadiness.swift"]
    assert 'disagreementMessage: "Long ranks disagree on admitted source, input, arithmetic or scheduling before clock start"' in wrapper
    assert "return .init(agreementFingerprint: agreement.fingerprint, readinessMaterialSHA256: digest)" in wrapper
    assert "material: { .request(agreementFingerprint: agreement.fingerprint) }" in wrapper
    material = proposed["QwenLongPrefillReadinessMaterial.swift"]
    assert 'sha256(Data(("qwen-profiled-prefill-readiness-v1|" + agreementFingerprint).utf8))' in material
    assert 'sha256(Data(("qwen-long-prefill-resident-cohort-readiness-v1|" + agreementFingerprint).utf8))' in material
    assert "private init(digest: String)" in material

    owner = proposed["QwenLongPrefillResidentRankOwner.swift"]
    old_owner = (ROOT / "originals/QwenLongPrefillResidentRankOwner.swift").read_text()
    marker = "/// Internal cohort seam"
    assert owner[:owner.index(marker)] == old_owner[:old_owner.index(marker)]
    expected_owner = old_owner.replace(
        "    try QwenLongPrefillResidentRankAdmission.validate(options: options, requests: requests, warmupCount: warmupCount)",
        "    let cohortAgreement = try QwenLongPrefillResidentCohortAgreement(\n        options: options, requests: requests, warmupCount: warmupCount)",
    ).replace(
        "            let receipt = try autoreleasepool {",
        "            let cohortReadiness = try requireQwenLongPrefillResidentCohortReadiness(\n                cohortAgreement, collective: collective, check: checked)\n            let receipt = try autoreleasepool {",
    ).replace(
        "            return .init(rank: collective.rank, sourceLoad: receipt, arithmeticEnvironment: first.arithmetic,",
        "            return .init(rank: collective.rank, cohortAgreement: cohortAgreement.descriptor,\n                cohortReadiness: cohortReadiness, sourceLoad: receipt, arithmeticEnvironment: first.arithmetic,",
    )
    assert owner == expected_owner
    assert owner.index("let cohortAgreement =") < owner.index("let collective =")
    assert owner.index("let cohortReadiness =") < owner.index("let loaded = try loadVerifiedQwenLayerStage")
    assert owner.count("loadVerifiedQwenLayerStage(") == 1

    old_report = (ROOT / "originals/QwenLongPrefillResidentRankReport.swift").read_text()
    assert proposed["QwenLongPrefillResidentRankReport.swift"] == old_report.replace(
        "    let sourceLoad: QwenLayerStageLoadReceipt",
        "    let cohortAgreement: QwenLongPrefillResidentCohortAgreement.Descriptor\n    let cohortReadiness: QwenLongPrefillResidentCohortReadiness\n    let sourceLoad: QwenLayerStageLoadReceipt",
    )
    descriptor = proposed["QwenLongPrefillResidentCohortAgreement.swift"]
    assert descriptor.index("try QwenLongPrefillResidentRankAdmission.validate") < descriptor.index("let first = requests[0]")
    assert "maximumEncodedBytes = 16_384" in descriptor and "guard bytes.count <= Self.maximumEncodedBytes" in descriptor
    assert "excludedWarmup: ordinal < warmupCount" in descriptor
    assert "recordedRequestFingerprint: request.local.request.fingerprint" in descriptor
    assert "promptFileSHA256: request.local.promptFileSHA256" in descriptor
    assert "resourceAdmissionSHA256: sha256(try canonicalJSONData(first.local.resource))" in descriptor
    for forbidden in ["MLX", "DispatchTime", "Data(contentsOf", "FileHandle", "FileManager", "ProcessInfo", "modelDirectory", "tokensFile"]:
        assert forbidden not in descriptor
    for name in ["QwenLongPrefillResidentCohortFixture.swift", "QwenLongPrefillResidentCohortAgreementCheck.swift", "QwenLongPrefillReadinessMaterialCheck.swift"]:
        for forbidden in ["MLXArray", "Collective(", "Data(contentsOf", "FileHandle", "FileManager", "ProcessInfo"]:
            assert forbidden not in proposed[name]
    fixture = proposed["QwenLongPrefillResidentCohortAgreementCheck.swift"]
    assert fixture.count("    try require(") == 6
    assert fixture.count("    try different(") == 8
    assert fixture.count("    try reject(") == 17
    assert "fixture.request(2, prompt: fixture.promptB, cut: nil)" in fixture
    vectors = proposed["QwenLongPrefillReadinessMaterialCheck.swift"]
    for domain in ["qwen-profiled-prefill-readiness-v1|", "qwen-long-prefill-resident-cohort-readiness-v1|"]:
        for character in ["a", "0"]:
            assert hashlib.sha256((domain + character * 64).encode()).hexdigest() in vectors
    old_main = (ROOT / "originals/Main.swift").read_text()
    call = "        try checkQwenLongPrefillResidentRankAdmission()"
    assert proposed["Main.swift"] == old_main.replace(call, call + "\n        try checkQwenLongPrefillResidentCohortAgreement()")


def main():
    proposed = {p.name: p.read_text() for p in sorted((ROOT / "proposed").glob("*.swift"))}
    assert len(proposed) == 11
    verify(proposed)
    bases = json.loads((ROOT / "base-source-pins.json").read_text())["files"]
    for record in bases:
        expected = record["sha256"]
        assert hashlib.sha256((ROOT / record["saved_original"]).read_bytes()).hexdigest() == expected
        assert hashlib.sha256((REPO / record["repository_path"]).read_bytes()).hexdigest() == expected
    patch = ""
    for name, text in sorted(proposed.items()):
        original = ROOT / "originals" / name
        before = original.read_text().splitlines(True) if original.exists() else []
        patch += "".join(difflib.unified_diff(before, text.splitlines(True),
            fromfile="a/" + PREFIX + name if original.exists() else "/dev/null", tofile="b/" + PREFIX + name))
    assert patch == (ROOT / "runtime.patch").read_text()
    mutations = [
        ("old readiness domain", "QwenLongPrefillReadinessMaterial.swift", "qwen-profiled-prefill-readiness-v1|", "qwen-profiled-prefill-readiness-v2|"),
        ("exchange byte bound", "QwenLongPrefillReadinessExchange.swift", "maximumBytes: 256", "maximumBytes: 257"),
        ("lost native error check", "QwenLongPrefillReadinessExchange.swift", "try error.check(); try check(); try error.check()", "try check()"),
        ("warmup off by one", "QwenLongPrefillResidentCohortAgreement.swift", "ordinal < warmupCount", "ordinal <= warmupCount"),
        ("logical instead of raw pin", "QwenLongPrefillResidentCohortAgreement.swift", "promptFileSHA256: request.local.promptFileSHA256", "promptFileSHA256: request.local.promptTokenIDsSHA256"),
        ("request loop changed", "QwenLongPrefillResidentRankOwner.swift", "ordinal < warmupCount", "ordinal <= warmupCount"),
    ]
    rejected = []
    for label, name, before, after in mutations:
        assert before in proposed[name]
        changed = dict(proposed); changed[name] = changed[name].replace(before, after, 1)
        try:
            verify(changed)
        except AssertionError:
            rejected.append(label)
        else:
            raise AssertionError("Source mutation admitted: " + label)
    result = {"kind": "resident_cohort_agreement_source_checks", "passed": True,
        "proposed_swift_files": 11, "saved_originals_unchanged": len(bases),
        "readiness_body_exact_after_three_named_substitutions": True,
        "private_owner_request_release_body_unchanged": True,
        "source_mutations_rejected": rejected, "independent_sha_vectors": 4,
        "prospective_swift_cases": {"accepted": 6, "distinct_valid_peer_agreements": 8, "rejected": 17},
        "swift_compiled_or_executed": False, "native_or_ssh_executed": False}
    raw = (json.dumps(result, indent=2, sort_keys=True) + "\n").encode()
    output = ROOT / "source-checks.json"
    if output.exists():
        assert output.read_bytes() == raw, "Refusing to replace a differing source-check receipt"
    else:
        output.write_bytes(raw)
    print(json.dumps(result, sort_keys=True))


if __name__ == "__main__":
    main()
