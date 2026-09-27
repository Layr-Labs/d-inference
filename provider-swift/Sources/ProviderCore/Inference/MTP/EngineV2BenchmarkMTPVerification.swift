import MLXLLM
import MLXLMCommon

/// Explicit offline Gemma verification control. Normal serving never supplies
/// this value; automatic remains subject to the ordinary provider work cap.
@_spi(Benchmarking)
public enum EngineV2BenchmarkMTPVerification: String, Sendable {
    case automatic
    case serialTarget = "serial_target"

    public enum Failure: Error, Equatable {
        case invalidScope, unsupportedTargetOrAssistant, unexpectedConfiguration, unexpectedEffectiveMode
        case unexpectedVerificationRounds
    }

    func validateScope(mtpEnabled: Bool, concurrency: Int, productionGrant: Bool,
        backend: String, environment: [String: String]) throws
    {
        guard mtpEnabled, concurrency == 1, productionGrant,
            ["contiguous", "paged"].contains(backend),
            !PrefixCachePolicy.isGloballyEnabled(environment: environment),
            !PrefixCachePolicy.isMemoryEnabled(environment: environment) else {
            throw Failure.invalidScope
        }
    }

    func applying(to configuration: CBv2MTPConfig, target: any LanguageModel,
        drafter: (any CBv2MTPDrafter)?) throws -> CBv2MTPConfig
    {
        guard target is Gemma4TextModel, let drafter,
            drafter.mtpTargetIdentity == ObjectIdentifier(target),
            !(drafter is any CBv2MTPRequestStatefulDrafter),
            drafter.requiredVerificationMode == nil || drafter.requiredVerificationMode == .automatic else {
            throw Failure.unsupportedTargetOrAssistant
        }
        guard configuration.enabled, configuration.fixedDraftTokens == 1,
            configuration.verificationMode == .automatic else {
            throw Failure.unexpectedConfiguration
        }
        var result = configuration
        result.verificationMode = self == .automatic ? .automatic : .serialTarget
        return result
    }

    public func validateObservedMetrics(_ metrics: CBv2MTPMetrics?, requireRounds: Bool = false) throws {
        guard let metrics, metrics.active,
            metrics.verificationMode == (self == .automatic ? .automatic : .serialTarget) else {
            throw Failure.unexpectedEffectiveMode
        }
        guard requireRounds else { return }
        let selected = self == .automatic
            ? metrics.rectangularVerificationRounds : metrics.serialVerificationRounds
        let other = self == .automatic
            ? metrics.serialVerificationRounds : metrics.rectangularVerificationRounds
        guard metrics.rounds > 0, selected > 0, other == 0 else {
            throw Failure.unexpectedVerificationRounds
        }
    }
}
