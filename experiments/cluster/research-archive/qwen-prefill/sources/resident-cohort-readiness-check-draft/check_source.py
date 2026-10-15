#!/usr/bin/env python3
"""Source/hash/patch checks only. Does not import or execute native helpers."""
from pathlib import Path
import difflib
import hashlib
import json

ROOT = Path(__file__).resolve().parent
REPO = ROOT.parent.parent / "d-inference"
PREFIX = "experiments/cluster/inference/Sources/ClusterInference/"


def verify(sources):
    admission = sources["QwenLongPrefillCohortReadinessAdmission.swift"]
    assert admission.index("try Self.validateOptions(options)") < admission.index("let fixture =")
    assert 'let allowed: Set<String> = ["--mode", "--transport", "--epoch", "--cohort-readiness-case", "--timeout-seconds"]' in admission
    assert "guard arguments.count == allowed.count * 2" in admission
    assert "allowed.contains(flag), values[flag] == nil" in admission
    assert 'values["--timeout-seconds"] == String(options.timeoutSeconds)' in admission
    assert "(1...30).contains(options.timeoutSeconds)" in admission
    assert "options.modelDirectory == nil, !options.synthetic" in admission
    assert "options.prefillPhaseTraceFile == nil, options.prefillOwnerTraceFile == nil" in admission
    assert "warmupCount: fixtureCase == .match ? 1 : 0" in admission
    assert "agreements = [first, second]" in admission
    assert "guard (0..<2).contains(rank)" in admission
    for name in ["MLX", "Collective(", "ProcessInfo", "FileManager", "FileHandle", "Data(contentsOf"]:
        # The explanatory comment can name MLX, but no import/call is present.
        if name == "MLX":
            assert "import MLX" not in admission
        else:
            assert name not in admission
    options = sources["Options.swift"]
    early = options.index("try QwenLongPrefillCohortReadinessAdmission.validateArguments(arguments, options: self)")
    assert early < options.index("// Check the original CLI mode")
    assert "} else if cohortReadinessCase != nil {" in options
    assert "if mode == .qwenLongPrefillCohortReadinessCheck { try QwenLongPrefillCohortReadinessAdmission.validateOptions(self) }" in options
    native = sources["QwenLongPrefillCohortReadinessCheck.swift"]
    assert native.count("let collective = try Collective(transport: .loopbackTest)") == 1
    assert "admission.agreement(forRank: collective.rank)" in native
    assert native.index("let readiness = try requireQwenLongPrefillResidentCohortReadiness") < native.index("let report =")
    assert "let readinessExchangePassed = true" in native
    assert "let modelConstructed = false, weightsMaterialized = false, requestsExecuted = false" in native
    assert "canonicalJSONData(report).count < 65_536" in native
    for forbidden in ["ProcessInfo", "loadVerified", "loadModel(", "runQwenLongPrefillRankRequest", "eval(", "synchronize()", "Memory."]:
        assert forbidden not in native
    main = sources["Main.swift"]
    branch = main[main.index("        if options.mode == .qwenLongPrefillCohortReadinessCheck {"):main.index("        let localInputs =")]
    assert branch.index("let admission =") < branch.index("_ = MLXArray(0)") < branch.index("let report =")
    assert branch.index("try error.check()\n                try emitJSON(report)") > branch.index("let report =")
    assert "return\n" in branch and "preflight(" not in branch
    old = (ROOT / "originals/Main.swift").read_text()
    stripped = main.replace(branch, "").replace("\n            try checkQwenLongPrefillCohortReadinessAdmission()", "")
    aligned_old = old.replace("\n        try checkQwenLongPrefillResidentCohortAgreement()\n",
        "\n            try checkQwenLongPrefillResidentCohortAgreement()\n")
    assert stripped == aligned_old
    fixture = sources["QwenLongPrefillCohortReadinessAdmissionCheck.swift"]
    assert fixture.count('    try identity("') == 5
    assert "accepted.count == 3, rejected.count == 42, identities.count == 5" in fixture
    assert "withoutWarmupLabels(mismatch0.descriptor) == withoutWarmupLabels(mismatch1.descriptor)" in fixture
    for ordinal in [1, 2]:
        digest = hashlib.sha256(("qwen-cohort-readiness-fixture-request-v1|" + "1" * 32 + "|" + str(ordinal)).encode()).hexdigest()[:32]
        assert digest in fixture
    for forbidden in ["MLXArray", "Collective(", "Data(contentsOf", "ProcessInfo", "FileHandle"]:
        assert forbidden not in fixture


def main():
    sources = {p.name: p.read_text() for p in sorted((ROOT / "proposed").glob("*.swift"))}
    assert len(sources) == 5
    verify(sources)
    base = json.loads((ROOT / "base-source-pins.json").read_text())["files"]
    for record in base:
        assert hashlib.sha256((ROOT / record["saved_original"]).read_bytes()).hexdigest() == record["sha256"]
        assert hashlib.sha256((REPO / record["repository_path"]).read_bytes()).hexdigest() == record["sha256"]
    dependencies = json.loads((ROOT / "dependency-pins.json").read_text())["files"]
    for record in dependencies:
        raw = (REPO / record["path"]).read_bytes()
        assert len(raw) == record["size_bytes"] and hashlib.sha256(raw).hexdigest() == record["sha256"]
    patch = ""
    for name, text in sorted(sources.items()):
        original = ROOT / "originals" / name
        before = original.read_text().splitlines(True) if original.exists() else []
        patch += "".join(difflib.unified_diff(before, text.splitlines(True),
            fromfile="a/" + PREFIX + name if original.exists() else "/dev/null", tofile="b/" + PREFIX + name))
    assert patch == (ROOT / "runtime.patch").read_text()
    mutations = [
        ("raw argument count", "QwenLongPrefillCohortReadinessAdmission.swift", "arguments.count == allowed.count * 2", "arguments.count >= allowed.count * 2"),
        ("native timeout", "QwenLongPrefillCohortReadinessAdmission.swift", "(1...30).contains", "(1...300).contains"),
        ("warmup mismatch lost", "QwenLongPrefillCohortReadinessAdmission.swift", "fixtureCase == .match ? 1 : 0", "fixtureCase == .match ? 1 : 1"),
        ("rank selected before native admission", "QwenLongPrefillCohortReadinessCheck.swift", "admission.agreement(forRank: collective.rank)", "admission.agreement(forRank: 0)"),
        ("success record cap", "QwenLongPrefillCohortReadinessCheck.swift", "canonicalJSONData(report).count < 65_536", "canonicalJSONData(report).count < 1_048_576"),
        ("false request execution claim", "QwenLongPrefillCohortReadinessCheck.swift", "requestsExecuted = false", "requestsExecuted = true"),
    ]
    rejected = []
    for label, name, before, after in mutations:
        assert before in sources[name]
        changed = dict(sources); changed[name] = changed[name].replace(before, after, 1)
        try:
            verify(changed)
        except AssertionError:
            rejected.append(label)
        else:
            raise AssertionError("Source mutation admitted: " + label)
    result = {"kind": "resident_cohort_readiness_entry_source_checks", "passed": True,
        "proposed_swift_files": 5, "saved_originals_matched": len(base), "unchanged_dependencies_matched": len(dependencies),
        "original_main_preserved_after_two_hunks_and_whitespace_alignment": True, "epoch_sha_vectors": 2,
        "prospective_swift_cases": {"accepted": 3, "rejected": 42, "identities": 5},
        "source_mutations_rejected": rejected, "compiler_native_or_ssh_executed": False}
    raw = (json.dumps(result, indent=2, sort_keys=True) + "\n").encode()
    output = ROOT / "source-checks.json"
    if output.exists():
        assert output.read_bytes() == raw, "Refusing to replace a differing source-check receipt"
    else:
        output.write_bytes(raw)
    print(json.dumps(result, sort_keys=True))


if __name__ == "__main__":
    main()
