"""Exact inverse of shared-driver hooks and unchanged proposal owner bodies."""
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parent
BASE = Path("libs/darkbloom-cluster/Sources/DarkbloomClusterRuntime")


def replace(raw, before, after):
    assert raw.count(before) == 1, before
    return raw.replace(before, after, 1)


def check():
    name = BASE / "QwenLayerStageGenerationDriver.swift"
    raw = (ROOT / "proposed" / name).read_text()
    raw = replace(raw, "func runQwenLayerStageGenerationCore(", "private func runQwenLayerStageGenerationCore(")
    raw = replace(raw, "diagnostics: QwenGenerationDiagnosticCapture?, probe: QwenLayerStageMTPProbe? = nil,",
                  "diagnostics: QwenGenerationDiagnosticCapture?,")
    raw = replace(raw, '''            if probe != nil {
                guard diagnostics == nil, agreement.prefillPolicy == .serial else {
                    throw ProbeError("MTP proposal probe cannot overlap recording or lookahead")
                }
            }
''', "")
    raw = replace(raw, "probe?.readinessFingerprint ?? agreement.fingerprint", "agreement.fingerprint")
    raw = replace(raw, '''                let owned = try probe?.makeSession(loaded: loaded, plan: plan, check: checked)
                    ?? QwenLayerStageSession(stage: loaded, plan: plan, generationRequest: agreement.request)
''', '''                let owned = try QwenLayerStageSession(stage: loaded, plan: plan, generationRequest: agreement.request)
''')
    raw = replace(raw, "transport: transport, expected: expected, probe: probe, check: checked)",
                  "transport: transport, expected: expected, check: checked)")
    raw = replace(raw, "                        try probe?.observedFrame(expected.frame, generation: control, check: checked)\n", "")
    raw = replace(raw, "                        try probe?.afterDecision(generation: control, check: checked)\n", "")
    raw = replace(raw, '''                if let probe {
                    try probe.finish(session: owned, reason: reason, count: control.selectedTokenCount,
                        lastToken: lastToken, check: checked)
                } else {
                    try owned.finishGeneration(reason, selectedTokenCount: control.selectedTokenCount, lastTokenID: lastToken)
                }
''', '''                try owned.finishGeneration(reason, selectedTokenCount: control.selectedTokenCount, lastTokenID: lastToken)
''')
    raw = replace(raw, '''                if let probe {
                    try probe.cancel(session: session, primary: primary)
                } else {
                    do { try session?.cancel() }
                    catch { throw ProbeError("Generation failed (\\(primary)); local retirement also failed (\\(error))") }
                }
''', '''                do { try session?.cancel() }
                catch { throw ProbeError("Generation failed (\\(primary)); local retirement also failed (\\(error))") }
''')
    raw = replace(raw, "    probe: QwenLayerStageMTPProbe? = nil, check: () throws -> Void\n", "    check: () throws -> Void\n")
    raw = replace(raw, '''        if transport.rank == 1, let probe {
            guard let incoming else { throw ProbeError("MTP probe requires the actual producer residual") }
            return try probe.forward(tokens: tokens, frame: frame, incoming: incoming, check: check)
        }
''', "")
    assert raw.encode() == (ROOT / "originals" / name).read_bytes()

    name = BASE / "QwenResidentMTPRequest.swift"
    raw = (ROOT / "proposed" / name).read_text()
    raw = replace(raw, '''
    /// Borrowed only by the shared private generation driver. The probe routes
    /// every forward and retirement through this owner while it is active.
    var probeSession: QwenLayerStageSession { session }
    var probeAssistantInputCount: Int? { assistantState?.committedInputCount }
    var probeAssistantRequestReleased: Bool {
        isRetired && assistantState == nil && pending == nil && carry == nil
    }
''', "")
    start = raw.index("    /// Ordinary target execution of the agreed seed.")
    end = raw.index("    /// Cleanup deliberately has no expired deadline/resource callback.", start)
    raw = raw[:start] + raw[end:]
    assert raw.encode() == (ROOT / "originals" / name).read_bytes()

    sink = Path("libs/darkbloom-cluster-worker/Sources/DarkbloomClusterWorker/ResidentEvidenceSink.swift")
    assert (ROOT / "proposed" / sink).read_bytes() == (ROOT / "lineage/benchmark-worker/ResidentEvidenceSink.swift").read_bytes()
    probe = (ROOT / "proposed" / BASE / "QwenLayerStageMTPProbe.swift").read_text()
    cleanup = probe[probe.index("    func cancel(session:"):probe.index("\n    func result(")]
    fixture = (ROOT / "Tests/ProbeCleanupCheck.swift").read_text()
    assert fixture.count(cleanup) == 1
    # Pipeline's independent target-transaction work owns these exact seams.
    for name in ["CBv2OwnedRequestState.swift", "QwenLayerStageSession.swift"]:
        assert not (ROOT / "proposed" / BASE / name).exists()
    return {"sharedDriverOriginalRestoredExactly": True, "priorProposalOwnerBodiesRestoredExactly": True,
        "existingEvidenceSinkUnchanged": True, "actualCleanupMethodCopiedExactlyForPendingCPUCheck": True,
        "targetTransactionFilesChanged": False,
        "compilerOrModelExecuted": False,
        "sources": [{"path": p.relative_to(ROOT / "proposed").as_posix(),
                     "sha256": hashlib.sha256(p.read_bytes()).hexdigest()}
                    for p in sorted((ROOT / "proposed").rglob("*.swift"))]}


if __name__ == "__main__":
    print(json.dumps(check(), indent=2, sort_keys=True))
