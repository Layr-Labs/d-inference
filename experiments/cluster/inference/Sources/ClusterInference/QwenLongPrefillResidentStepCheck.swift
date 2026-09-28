import Foundation

struct QwenLongPrefillResidentStepCheckResult: Encodable {
    let kind = "qwen_long_prefill_resident_step_check", cpuOnly = true
    let acceptedCases: [String], rejectedCases: [String], interruptionCases: [String]
    let nativeRequestsOrModelsConstructed = false
    let nativeRetirementOrReleaseQualified = false
}

/// Fabricated callbacks exercise the actual generic sequencer. This does not
/// substitute for the private owner's real autorelease/weak-model checks.
func checkQwenLongPrefillResidentSteps() throws -> QwenLongPrefillResidentStepCheckResult {
    enum Stop: Error { case expected }
    func step(_ ordinal: Int, warmup: Bool = false, id: Int? = nil,
              history: String = String(repeating: "a", count: 64),
              prompt: String = String(repeating: "b", count: 64)) -> QwenLongPrefillResidentRequestStep {
        let suffix = String(format: "%012x", (id ?? ordinal) + 1)
        return .init(ordinal: ordinal, excludedWarmup: warmup,
            requestID: UUID(uuidString: "00000000-0000-0000-0000-" + suffix)!,
            recordedRequestFingerprint: history, promptFileSHA256: prompt)
    }
    let four = (0..<4).map { step($0, warmup: $0 == 0) }
    var accepted: [String] = [], rejected: [String] = [], interruptions: [String] = []
    for (name, steps) in [("one measured request", [step(0)]), ("warmup then three measured", four)] {
        var events: [String] = []
        let result = try runQwenLongPrefillResidentSteps(steps: steps,
            beforeRequest: { events.append("permit:\($0.ordinal)") },
            request: { events.append("retired:\($0.ordinal)"); return $0.ordinal },
            onRequestResult: { events.append("publish:\($0.ordinal):\($1)") }, check: {})
        let expected = steps.flatMap { ["permit:\($0.ordinal)", "retired:\($0.ordinal)", "publish:\($0.ordinal):\($0.ordinal)"] }
        guard result == Array(0..<steps.count), events == expected else {
            throw ProbeError("Resident step callback order or result changed")
        }
        accepted.append(name)
    }
    let invalid: [(String, [QwenLongPrefillResidentRequestStep])] = [
        ("empty", []), ("fifth request", (0..<5).map { step($0) }),
        ("duplicate UUID", [step(0), step(1, id: 0)]),
        ("nonzero first ordinal", [step(1)]), ("skipped ordinal", [step(0), step(2)]),
        ("warmup after measured", [step(0), step(1, warmup: true)]),
        ("all warmup", [step(0, warmup: true)]),
        ("uppercase history", [step(0, history: String(repeating: "A", count: 64))]),
        ("short prompt pin", [step(0, prompt: String(repeating: "b", count: 63))]),
    ]
    for (name, steps) in invalid {
        var callbacks = 0
        do {
            _ = try runQwenLongPrefillResidentSteps(steps: steps,
                beforeRequest: { _ in callbacks += 1 }, request: { _ in callbacks += 1; return 0 },
                onRequestResult: { _, _ in callbacks += 1 }, check: { callbacks += 1 })
        } catch {
            guard callbacks == 0 else { throw ProbeError("Invalid resident sequence invoked a callback") }
            rejected.append(name); continue
        }
        throw ProbeError("Resident step sequence accepted invalid case: " + name)
    }

    for failure in ["permission", "request", "publication", "check-before-permission",
                    "check-after-permission", "check-after-request", "check-after-publication"] {
        var events: [String] = [], checks = 0
        let checkAt = ["check-before-permission": 1, "check-after-permission": 2,
                       "check-after-request": 3, "check-after-publication": 4][failure]
        do {
            _ = try runQwenLongPrefillResidentSteps(steps: four,
                beforeRequest: {
                    events.append("permit:\($0.ordinal)")
                    if failure == "permission" { throw Stop.expected }
                }, request: {
                    events.append("request:\($0.ordinal)")
                    if failure == "request" { throw Stop.expected }
                    events.append("retired:\($0.ordinal)")
                    return $0.ordinal
                }, onRequestResult: {
                    events.append("publish:\($0.ordinal):\($1)")
                    if failure == "publication" { throw Stop.expected }
                }, check: {
                    checks += 1
                    if let checkAt, checks == checkAt { throw Stop.expected }
                })
        } catch Stop.expected {
            let expected: [String]
            switch failure {
            case "check-before-permission": expected = []
            case "permission", "check-after-permission": expected = ["permit:0"]
            case "request": expected = ["permit:0", "request:0"]
            case "check-after-request": expected = ["permit:0", "request:0", "retired:0"]
            default: expected = ["permit:0", "request:0", "retired:0", "publish:0:0"]
            }
            guard events == expected else { throw ProbeError("Resident callbacks continued after failure") }
            interruptions.append(failure); continue
        }
        throw ProbeError("Resident step sequence swallowed expected callback/check failure")
    }
    guard accepted.count == 2, rejected.count == 9, interruptions.count == 7 else {
        throw ProbeError("Resident step fixture coverage changed")
    }
    return .init(acceptedCases: accepted, rejectedCases: rejected, interruptionCases: interruptions)
}
