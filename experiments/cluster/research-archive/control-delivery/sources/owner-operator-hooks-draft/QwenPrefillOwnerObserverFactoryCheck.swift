import Foundation

struct QwenPrefillOwnerObserverFactoryCheckResult: Encodable {
    let kind = "qwen_prefill_owner_observer_factory_check"
    let acceptedChecks: Int
    let expectedFailurePaths: Int
    let nativeExecution = false
}

private enum QwenOwnerFactoryFixtureError: Error {
    case assertion, factory
}

/// Pure selection/pass-through fixture; root owns compilation and execution.
/// The concrete outer factory separately validates identity and one-shot use.
func checkQwenPrefillOwnerObserverFactory() throws -> QwenPrefillOwnerObserverFactoryCheckResult {
    func require(_ condition: Bool) throws {
        if !condition { throw QwenOwnerFactoryFixtureError.assertion }
    }
    func frame(_ index: Int) -> QwenLayerStageFrame {
        .init(sequence: index, phase: .prefill, tokenOffset: index * 512,
              tokenCount: 512, finalPromptChunk: index == 15)
    }
    var calls: [QwenLayerStageFrame] = []
    var observed: [CBv2OwnerPhaseObservation] = []
    let factory: QwenPrefillOwnerObserverFactory = { selected in
        calls.append(selected)
        return { observed.append($0) }
    }
    for index in 0..<16 where index != 7 {
        if let _ = try qwenPrefillSelectedOwnerObserver(for: frame(index), factory: factory) {
            throw QwenOwnerFactoryFixtureError.assertion
        }
    }
    try require(calls.isEmpty && observed.isEmpty)
    if let _ = try qwenPrefillSelectedOwnerObserver(for: frame(7), factory: nil) {
        throw QwenOwnerFactoryFixtureError.assertion
    }
    try require(calls.isEmpty)
    guard let observer = try qwenPrefillSelectedOwnerObserver(for: frame(7), factory: factory) else {
        throw QwenOwnerFactoryFixtureError.assertion
    }
    try require(calls == [frame(7)] && observed.isEmpty)
    let value = CBv2OwnerPhaseObservation(phase: .graphConstructionBegin,
        tokenCount: 512, committedTokens: 3584)
    try observer(value)
    try require(observed == [value] && calls.count == 1)
    var failureCalls = 0
    let failing: QwenPrefillOwnerObserverFactory = { _ in
        failureCalls += 1
        throw QwenOwnerFactoryFixtureError.factory
    }
    if let _ = try qwenPrefillSelectedOwnerObserver(for: frame(6), factory: failing) {
        throw QwenOwnerFactoryFixtureError.assertion
    }
    try require(failureCalls == 0)
    do {
        _ = try qwenPrefillSelectedOwnerObserver(for: frame(7), factory: failing)
        throw QwenOwnerFactoryFixtureError.assertion
    } catch QwenOwnerFactoryFixtureError.factory {}
    try require(failureCalls == 1)
    return .init(acceptedChecks: 6, expectedFailurePaths: 1)
}
