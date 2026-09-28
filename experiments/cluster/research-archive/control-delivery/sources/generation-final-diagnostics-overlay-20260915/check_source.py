"""Source conservation and pin checks; no Swift/native/model execution."""
from pathlib import Path
import hashlib
import json

ROOT = Path(__file__).resolve().parent

def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

for record in json.loads((ROOT / "source-pins.json").read_text())["sources"]:
    assert digest(Path(record["path"])) == record["sha256"], record["path"]
for record in json.loads((ROOT / "foundation-source-list.json").read_text())["sources"]:
    assert digest(Path(record["path"])) == record["sha256"], record["path"]

pins = {Path(x["path"]).name: Path(x["path"]) for x in json.loads((ROOT / "source-pins.json").read_text())["sources"]}
assert (ROOT / "originals/QwenLayerStageGenerationDriver.swift").read_bytes() == pins["QwenLayerStageGenerationDriver.swift"].read_bytes()
assert (ROOT / "Sources/QwenLayerStageRecordedLogits.swift").read_bytes() == pins["QwenLayerStageRecordedLogits.swift"].read_bytes()
source = pins["QwenLayerStageRecordedEvidence.swift"].read_text()
expected = "import Foundation\n\n" + source[source.index("struct QwenRecordedState:"):source.index("\nstruct QwenRecordedFrameEvidence:")] + "\n"
assert (ROOT / "Sources/QwenRecordedState.swift").read_text() == expected
source = pins["QwenLayerStageRankFrameCapture.swift"].read_text()
expected = "import Foundation\n\n" + source[source.index("/// Validate only this stage"):]
assert (ROOT / "Sources/QwenLayerStageRankStateCapture.swift").read_text() == expected

old = (ROOT / "originals/QwenLayerStageGenerationDriver.swift").read_text()
new = (ROOT / "Sources/QwenLayerStageGenerationDriver.swift").read_text()
tail = "private func requireGenerationSource("
assert old[old.index(tail):] == new[new.index(tail):], "Source/forward/token functions changed"
core = new[new.index("private func runQwenLayerStageGenerationCore("):]
core = core[core.index("            try requireGenerationSource("):core.index("\n            } catch {")]
core = "\n".join(x[4:] if x.startswith("    ") else x for x in core.splitlines())
row = '''                    if control.phase == .retiring {
                        finalDecision = decision
                        // Both decision ACKs are complete, and rank1 still owns
                        // the final native row inside this frame's pool.
                        try diagnostics?.captureFinalRow(row, frame: expected.frame,
                            tokenID: selected, check: checked)
                    }'''
assert core.count(row) == 1
core = core.replace(row, "                    if control.phase == .retiring { finalDecision = decision }")
state = '''            // Snapshot committed local state before finishGeneration retires it.
            // No extra collective is introduced: the existing retirement ACK
            // exchange cannot complete until both local captures have returned.
            try diagnostics?.captureState(session: owned, stage: plan.stages[collective.rank],
                selectedTokenIDs: selectedTokens, completedFrames: control.completedFrames,
                committedTokens: control.committedTokens, reason: reason, check: checked)
'''
assert core.count(state) == 1
core = core.replace(state, "")
expected = old[old.index("        try requireGenerationSource("):old.index("\n        } catch {")]
assert core == expected, "Driver normal core changed beyond the two optional capture hooks"
assert "collective: collective, diagnostics: nil, onCommittedToken: onCommittedToken, check: check)" in new
assert new.index("try diagnostics?.captureFinalRow") < new.index("try diagnostics?.captureState") < new.index("try owned.finishGeneration")
assert new.index("try owned.finishGeneration") < new.index("try transport.exchangeRetirement") < new.index("guard control.isRetired")
assert "do { try nativeError.check() } catch { primary = error }" in new
assert "diagnostics?.discard()\n                control.cancel(); transport.retire()" in new
entry = new[new.index("func recordQwenLayerStageGenerationRequest("):new.index("private func runQwenLayerStageGenerationCore(")]
assert entry.index("let result = try runQwenLayerStageGenerationCore") < entry.index("return try capture.finish")

for record in json.loads((ROOT / "integration.json").read_text())["files"]:
    assert digest(ROOT / record["source"]) == record["sha256"], record["source"]
print(json.dumps({"sourcePins": 15, "foundationInputs": 9, "runtimeFiles": 9,
                  "exactHelperExtractions": 3, "normalDriverCoreConserved": True,
                  "nativeExecution": False}, sort_keys=True))
