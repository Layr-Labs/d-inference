import DarkbloomClusterProtocol
import Foundation

/// Unadvertised selection for an owned native correctness run. This creates a
/// load configuration for the same resident runtime, never an alternate engine
/// or an installed/provider capability. The ordinary configuration stays 9B.
@_spi(Benchmark) public enum QwenResidentNativeValidationModel: Sendable {
    case qwen38TwentySevenB

    public var runtimeModelID: String { QwenRegisteredDenseModel.qwen38TwentySevenB.rawValue }

    private var definition: QwenResidentModelDefinition {
        get throws { try QwenResidentModelDefinition(model: .qwen38TwentySevenB) }
    }

    public var supportedCuts: [Int] { get throws { try definition.supportedCuts } }

    public func configuration(identity: ClusterWorkerIdentity, modelDirectory: URL,
        rank: Int, stageCut: Int, deadlineUptimeNanoseconds: UInt64, now: UInt64
    ) throws -> QwenResidentLoadConfiguration {
        let selected = try definition, spec = selected.specification
        guard identity.modelID == runtimeModelID, identity.artifactSHA256 == spec.artifactSHA256,
              identity.configurationSHA256 == spec.configurationSHA256,
              selected.supportedCuts.contains(stageCut), (0...1).contains(rank),
              modelDirectory.isFileURL, deadlineUptimeNanoseconds > now,
              deadlineUptimeNanoseconds - now <= QwenResidentAdapterDefinition.maximumLifetimeNanoseconds else {
            throw ProbeError("Native validation requires the exact registered 27B identity, candidate cut and local lifetime")
        }
        // Full metadata, peer, source, bootstrap and resource validation remains
        // in QwenResidentAdmission/load. This entry does not bypass those gates.
        return .init(identity: identity, modelDirectory: modelDirectory, rank: rank,
            stageCut: stageCut, deadlineUptimeNanoseconds: deadlineUptimeNanoseconds,
            allocatorPolicy: .disableFreedBufferCache, prefillSchedule: .serial,
            nativeValidationModel: spec.model)
    }
}
