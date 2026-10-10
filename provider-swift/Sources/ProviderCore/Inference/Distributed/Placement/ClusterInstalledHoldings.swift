import Darwin
import Foundation
import DarkbloomClusterPlacement
import DarkbloomClusterProtocol

/// What each Mac holds while a session of the saved setup is up, for the
/// status view and the console. The layers come from the saved Plan; the
/// bytes from the artifact's layout as the plan tool installed beside this
/// Mac's worker reads it from the saved model directory (tensor headers and
/// `config.json`, milliseconds, no model load). It is what the plan says each
/// Mac holds, by the planner's own rule, and not a measurement of what a
/// worker has loaded.
public enum ClusterInstalledHoldings {
    /// The plan tool's file name: it is built and installed with the worker.
    public static let toolName = ClusterPlacementInstallation.toolName

    /// What a view shows: the holdings, or why they could not be read.
    public struct Observation: Encodable, Sendable, Equatable {
        public let holdings: ClusterPlacementHoldings?
        /// Why there is no figure; nil when there is one.
        public let detail: String?

        public init(holdings: ClusterPlacementHoldings?, detail: String?) {
            self.holdings = holdings; self.detail = detail
        }

        /// The line both views print.
        public var line: String {
            holdings?.line ?? "What each Mac holds was not read: \(detail ?? "no reason given")"
        }
    }

    /// Holdings of the saved setup with a layout already in hand. Pure.
    public static func compute(configuration: ClusterConfiguration, capability: ClusterRuntimeCapability,
                               layout: ClusterModelLayout, localPhysicalMemoryBytes: Int?,
                               pageSizeBytes: Int) throws -> ClusterPlacementHoldings {
        guard layout.runtimeModelID == capability.runtimeModelID, layout.artifactSHA256 == capability.artifactSHA256,
              layout.configurationSHA256 == capability.configurationSHA256 else {
            throw ClusterConfigurationError.invalid("The model directory's layout and the saved capability record describe different models")
        }
        let stages = try capability.selection(planSHA256: configuration.selectedPlanSHA256).stages.sorted { $0.rank < $1.rank }
        guard stages.count == configuration.peers.count, stages.count >= 2,
              stages.first?.sourceLayerStart == 0, stages.last?.sourceLayerEnd == layout.layerCount,
              zip(stages, stages.dropFirst()).allSatisfy({ $0.sourceLayerEnd == $1.sourceLayerStart }) else {
            throw ClusterConfigurationError.invalid("The saved Plan's stages do not cover the model's layers in rank order")
        }
        let local = configuration.peers[configuration.localRank].id
        return try ClusterPlacementHoldings.describe(layout: layout, labels: stages.map { configuration.peers[$0.rank].id },
            boundaries: stages.dropLast().map(\.sourceLayerEnd), mode: configuration.selectedGenerationMode,
            pageSizeBytes: pageSizeBytes, physicalMemoryBytes: localPhysicalMemoryBytes.map { [local: $0] } ?? [:],
            localLabel: local)
    }

    /// Reads the layout through the plan tool installed beside this Mac's
    /// worker and computes the holdings. The tool must be this user's own
    /// regular file that nobody else can write; it is run with fixed
    /// arguments and a bounded output, as the capability probe's child is.
    public static func read(configuration: ClusterConfiguration, capability: ClusterRuntimeCapability,
                            deadline: UInt64) throws -> ClusterPlacementHoldings {
        let local = configuration.peers[configuration.localRank]
        let tool = URL(fileURLWithPath: local.workerExecutable).deletingLastPathComponent()
            .appendingPathComponent(toolName)
        var information = stat()
        guard lstat(tool.path, &information) == 0 else {
            throw ClusterConfigurationError.invalid("\(toolName) is not installed beside this Mac's worker")
        }
        guard information.st_mode & S_IFMT == S_IFREG, information.st_uid == geteuid(), information.st_mode & 0o022 == 0,
              information.st_mode & 0o100 != 0 else {
            throw ClusterConfigurationError.invalid("\(toolName) beside this Mac's worker is not this user's own executable file")
        }
        let layout = try ClusterModelLayout.decode(DistributedCapabilityProbe.run(executable: tool,
            arguments: ["layout", "--model-dir", local.modelDirectory, "--json"], deadline: deadline,
            maximumOutputBytes: ClusterModelLayout.maximumEncodedBytes))
        return try compute(configuration: configuration, capability: capability, layout: layout,
            localPhysicalMemoryBytes: Int(clamping: ProcessInfo.processInfo.physicalMemory), pageSizeBytes: Int(getpagesize()))
    }

    /// The holdings or the reason, never a throw: a status view shows either.
    public static func observe(configuration: ClusterConfiguration, capability: ClusterRuntimeCapability,
                               deadline: UInt64) -> Observation {
        do { return .init(holdings: try read(configuration: configuration, capability: capability, deadline: deadline), detail: nil) }
        catch {
            // Printable characters only, bounded, as a check's detail is.
            let text = String(describing: error).filter { $0.unicodeScalars.allSatisfy { $0.value >= 32 && $0.value != 127 } }
            return .init(holdings: nil, detail: String(text.prefix(512)))
        }
    }

}
