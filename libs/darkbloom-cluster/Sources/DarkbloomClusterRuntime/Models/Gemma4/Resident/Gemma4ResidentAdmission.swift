import DarkbloomClusterProtocol
import Foundation

/// One rank's admitted load of a registered Gemma artifact. Nothing outside the
/// closed catalog reaches this value: the identity's model ID selects a row and
/// every other check is against that row.
struct Gemma4ResidentAdmission {
    let configuration: QwenResidentLoadConfiguration
    let configBytes: Data, manifestBytes: Data
    let specification: Gemma4RegisteredSpecification
    let plan: QwenLayerStagePlan
    let profile: QwenLayerStageGenerationProfile
    let arithmetic: Gemma4ArithmeticEnvironment.Receipt
    let arithmeticSHA256: String
    let jaccl: QwenResidentJACCLConfiguration

    init(configuration: QwenResidentLoadConfiguration, configBytes: Data, manifestBytes: Data,
         environment: [String: String], now: UInt64, read: (URL, Int) throws -> Data) throws {
        let identity = configuration.identity
        guard let spec = try? Gemma4RegisteredSpecification.registered(runtimeModelID: identity.modelID),
              (0...1).contains(configuration.rank),
              Gemma4ResidentAdapterDefinition.supportedCuts.contains(configuration.stageCut),
              Gemma4ResidentAdapterDefinition.supportedPrefillSchedules.contains(configuration.prefillSchedule),
              configuration.modelDirectory.isFileURL,
              identity.peers.count == 2, identity.peers[0].id != identity.peers[1].id,
              identity.peers.allSatisfy({ !$0.id.isEmpty && $0.id.utf8.count <= 128 &&
                  $0.id.utf8.allSatisfy({ (33...126).contains($0) }) && qwenStageWireIsSHA256($0.buildSHA256) }),
              configuration.deadlineUptimeNanoseconds > now,
              configuration.deadlineUptimeNanoseconds - now <= Gemma4ResidentAdapterDefinition.maximumLifetimeNanoseconds,
              (1...1_048_576).contains(configBytes.count), (1...4_194_304).contains(manifestBytes.count),
              identity.configurationSHA256 == spec.configurationSHA256,
              identity.artifactSHA256 == spec.artifactSHA256,
              sha256(configBytes) == spec.configurationSHA256,
              sha256(manifestBytes) == spec.manifestSHA256 else {
            throw ProbeError("Resident load requires a registered Gemma model's closed identity, one of its cuts and a bounded local lifetime")
        }
        // Before any model construction or native environment cache is used.
        arithmetic = try Gemma4ArithmeticEnvironment.admit(environment)
        arithmeticSHA256 = sha256(try canonicalJSONData(arithmetic))
        jaccl = try QwenResidentJACCLConfiguration.admit(environment: environment, read: read)
        guard jaccl.rank == configuration.rank else { throw ProbeError("Resident local rank differs from JACCL") }
        self.configuration = configuration; self.configBytes = configBytes; self.manifestBytes = manifestBytes
        specification = spec
        plan = try Gemma4LayerStagePlanning.plan(specification: spec, configuration: configBytes,
                                                 cut: configuration.stageCut)
        profile = try Gemma4ResidentAdapterDefinition.profile(specification: spec)
    }
}
