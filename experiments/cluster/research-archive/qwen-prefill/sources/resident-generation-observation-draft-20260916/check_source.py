#!/usr/bin/env python3
"""Small text/pin checks only; never invokes Swift, a fixture, or native code."""
import difflib
import hashlib
import json
from pathlib import Path

BASE = Path(__file__).resolve().parent
ANCESTOR = BASE.parent / "qwen27b-lookahead-native-build-20260915/workspace"
REL = Path("libs/darkbloom-cluster/Sources/DarkbloomClusterRuntime")
CHANGED = ("QwenLayerStageGenerationDriver.swift", "QwenLayerStageGenerationTransport.swift",
           "QwenGenerationLookaheadProducer.swift")
ADDED = ("QwenGenerationPhaseObservation.swift", "QwenGenerationPhaseBudget.swift",
         "QwenGenerationPhaseRecorder.swift", "QwenGenerationPhaseHook.swift")

def sha(data):
    return hashlib.sha256(data).hexdigest()

def once(source, old, new):
    assert source.count(old) == 1, (old, source.count(old))
    return source.replace(old, new)

def strip_markers(source):
    lines = source.splitlines(keepends=True)
    output, depth, count = [], 0, 0
    for line in lines:
        if not depth and line.lstrip().startswith("if let observation"):
            depth = line.count("{") - line.count("}")
            count += 1
        elif depth:
            depth += line.count("{") - line.count("}")
        else:
            output.append(line)
    assert depth == 0
    return "".join(output), count

def inverse(name, source):
    result, count = strip_markers(source)
    if name == CHANGED[0]:
        result = once(result, "    observation: QwenGenerationPhaseObserver? = nil,\n", "")
        assert result.count("observation: QwenGenerationPhaseObserver? = nil, check:") == 2
        result = result.replace("observation: QwenGenerationPhaseObserver? = nil, check:", "check:")
        assert result.count(", observation: observation") == 4
        result = result.replace(", observation: observation", "")
    elif name == CHANGED[1]:
        result = once(result, "    private let observation: QwenGenerationPhaseObserver?\n", "")
        result = once(result, "collective: Collective,\n         observation: QwenGenerationPhaseObserver? = nil) throws", "collective: Collective) throws")
        result = once(result, "; self.observation = observation", "")
    else:
        result = once(result, "    private let observation: QwenGenerationPhaseObserver?\n", "")
        result = once(result, ", observation: QwenGenerationPhaseObserver? = nil", "")
        result = once(result, "; self.observation = observation", "")
    assert "observation" not in result
    return result, count

def main():
    rows, patch = [], []
    for name in CHANGED:
        old = (BASE / "original" / REL / name).read_bytes()
        new = (BASE / "proposed" / REL / name).read_bytes()
        actual = (ANCESTOR / REL / name).read_bytes()
        assert old == actual, name
        restored, count = inverse(name, new.decode())
        assert restored.encode() == old, name
        if name == CHANGED[0]:
            marker = "private func runQwenLayerStageGenerationCore"
            assert old.decode().split(marker)[0] == new.decode().split(marker)[0]
        rows.append({"path": str(REL / name), "originalSHA256": sha(old),
                     "proposedSHA256": sha(new), "inverseExact": True,
                     "guardedMarkerBlocks": count})
        patch.extend(difflib.unified_diff(old.decode().splitlines(True), new.decode().splitlines(True),
            fromfile="a/" + str(REL / name), tofile="b/" + str(REL / name)))
    for name in ADDED:
        data = (BASE / "proposed" / REL / name).read_bytes()
        rows.append({"path": str(REL / name), "proposedSHA256": sha(data), "newFile": True})
        patch.extend(difflib.unified_diff([], data.decode().splitlines(True),
            fromfile="/dev/null", tofile="b/" + str(REL / name)))
    recorder = (BASE / "proposed" / REL / ADDED[2]).read_text()
    assert "static let nativeObservationEntryAvailable = false" in recorder
    assert "private init(" in recorder
    assert recorder.index("#if QWEN_GENERATION_PHASE_FIXTURE") < recorder.index("static func forCPUFixture") < recorder.index("#endif")
    schedule = (ANCESTOR / REL / "QwenLayerStageSchedule.swift").read_text()
    start = schedule.index("struct QwenLayerStageFrame:")
    end = schedule.index("\n}", start) + 2
    extracted = (BASE / "Tests/ExactFrame.swift").read_text()
    assert schedule[start:end] in extracted
    producer = (BASE / "proposed" / REL / CHANGED[2]).read_text()
    assert producer.index("guard original == nil, prepared == nil") < producer.index(".originalWrapperReleased") < producer.index("try window.completeSend") < producer.index("try transport.finishBoundaryConsumed")
    driver = (BASE / "proposed" / REL / CHANGED[0]).read_text()
    assert driver.count("if let observation, boundary.content.expectation.frame.phase == .prefill") == 8
    assert driver.index("try transport.exchangeRetirement") < driver.index(".requestRetired")
    assert "try requireGenerationSource" in driver
    report = {"schema": "qwen_resident_phase_source_checks_v1", "runtime": rows,
        "exactFrameSourceSHA256": sha(schedule.encode()), "exactFrameSHA256": sha(extracted.encode()),
        "productionWrappersByteIdentical": True, "nativeObservationEntryAvailable": False,
        "originalNativeCallsAndChecksPreservedByInverse": True,
        "swiftTypecheckExecuted": False, "cpuFixtureExecuted": False,
        "nativeOrModelOrRemoteExecuted": False,
        "hostReservationOrJSONAllocationBoundProved": False}
    (BASE / "runtime.patch").write_text("".join(patch))
    (BASE / "source-checks.json").write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    print(json.dumps({"sourceInverseFiles": len(CHANGED), "newRuntimeFiles": len(ADDED),
                      "markerBlocks": sum(x.get("guardedMarkerBlocks", 0) for x in rows),
                      "fixtureExecuted": False}, sort_keys=True))

if __name__ == "__main__":
    main()
