@testable import ProviderCore

/// A cancelled consumer can race a natural engine terminal. Only the settled
/// engine reason proves that the lifecycle test interrupted actual work.
struct ServingQualificationLifecycleOutcome: Sendable {
    let engineFinishReason: EngineFinishReason?
    var cancelled: Bool { engineFinishReason == .cancelled }
}
