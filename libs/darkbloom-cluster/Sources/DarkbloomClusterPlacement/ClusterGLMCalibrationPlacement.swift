import CryptoKit
import DarkbloomClusterProtocol
import Foundation

/// Observations used to choose a finite experiment. No value in this file can
/// mint native authorization, workspace evidence, a capability or READY.
public enum ClusterGLMCalibrationPlacement {
    public static let maximumBytes = 65_536
    public static let maximumAgeSeconds: Int64 = 120

    public struct Quote: Codable, Equatable, Sendable {
        public let cut: Int
        public let nativeBytes: Int
        public let hostBytes: Int
        public let combinedBytes: Int
        public init(cut: Int, nativeBytes: Int, hostBytes: Int, combinedBytes: Int) {
            self.cut = cut; self.nativeBytes = nativeBytes; self.hostBytes = hostBytes
            self.combinedBytes = combinedBytes
        }
    }
    public struct Snapshot: Codable, Sendable {
        public let version: Int
        public let rank: Int
        public let inputSHA256: String
        public let commonSHA256: String
        public let runtimeBinarySHA256: String
        public let sampledUnixSeconds: Int64
        public let expiresUnixSeconds: Int64
        public let profile: ClusterDeviceProfile
        /// Cost prior only. admittedCuts stays empty: this is not a serving layout.
        public let layout: ClusterModelLayout
        public let nativeAvailableBytes: Int
        public let hostAvailableBytes: Int
        public let combinedAvailableBytes: Int
        public let quotes: [Quote]
        public let refusals: [String]
        public let measurements: [ClusterSpeedMeasurement]
        public init(rank: Int, inputSHA256: String, commonSHA256: String, runtimeBinarySHA256: String,
                    sampledUnixSeconds: Int64, expiresUnixSeconds: Int64, profile: ClusterDeviceProfile,
                    layout: ClusterModelLayout, nativeAvailableBytes: Int, hostAvailableBytes: Int,
                    combinedAvailableBytes: Int, quotes: [Quote], refusals: [String],
                    measurements: [ClusterSpeedMeasurement]) {
            version = 1; self.rank = rank; self.inputSHA256 = inputSHA256; self.commonSHA256 = commonSHA256
            self.runtimeBinarySHA256 = runtimeBinarySHA256; self.sampledUnixSeconds = sampledUnixSeconds
            self.expiresUnixSeconds = expiresUnixSeconds; self.profile = profile; self.layout = layout
            self.nativeAvailableBytes = nativeAvailableBytes; self.hostAvailableBytes = hostAvailableBytes
            self.combinedAvailableBytes = combinedAvailableBytes; self.quotes = quotes
            self.refusals = refusals; self.measurements = measurements
        }
        public func validate(now: Int64) throws {
            try profile.validate(); try layout.validate()
            guard version == 1, (0...1).contains(rank), now >= sampledUnixSeconds,
                  sampledUnixSeconds >= 0, now - sampledUnixSeconds <= maximumAgeSeconds,
                  expiresUnixSeconds > now, expiresUnixSeconds - sampledUnixSeconds <= 3600,
                  [inputSHA256, commonSHA256, runtimeBinarySHA256].allSatisfy(isHash),
                  profile.memory.admits(0), nativeAvailableBytes > 0, hostAvailableBytes > 0,
                  combinedAvailableBytes > 0, combinedAvailableBytes <= profile.physicalMemoryBytes,
                  nativeAvailableBytes <= profile.allocatorLimitBytes,
                  layout.admittedCuts.isEmpty, layout.generationModes == [.pipeline],
                  layout.prefillSchedules == [.serial], layout.tensorParallel == nil,
                  layout.structuralCuts == Array(1..<layout.layerCount),
                  quotes.count <= layout.structuralCuts.count,
                  Set(quotes.map(\.cut)).count == quotes.count, refusals.count <= 2 * layout.layerCount,
                  refusals.allSatisfy({ $0.utf8.count <= 1024 }), measurements.count <= 128 else {
                throw ClusterPlacementError("Invalid, expired or unsupported GLM candidate snapshot")
            }
            for measurement in measurements { try measurement.validate() }
            for q in quotes {
                let sum = q.nativeBytes.addingReportingOverflow(q.hostBytes)
                guard layout.structuralCuts.contains(q.cut), q.nativeBytes > 0, q.hostBytes > 0,
                      !sum.overflow, q.combinedBytes == sum.partialValue,
                      q.nativeBytes <= nativeAvailableBytes, q.hostBytes <= hostAvailableBytes,
                      q.combinedBytes <= combinedAvailableBytes else {
                    throw ClusterPlacementError("GLM candidate exceeds its rank snapshot")
                }
            }
        }
    }
    public struct Decision: Codable {
        public let cut: Int
        public let mode: ClusterGenerationMode
        public let feasibleCuts: [Int]
        public let rankedCuts: [Int]
        public let prediction: ClusterPlacementPrediction
        public let speedSources: [ClusterDeviceSpeed.Source]
        public let absolutePrediction: Bool
        public let predictionBasis: String
        public let linkMeasured: Bool
        public let measuredBestSpeed: Bool
        public let calibratedEligible: Bool
        public let unsupportedModes: [String]
    }

    /// Exact fit filters first. Rank the surviving structural cuts with the
    /// existing planner's request-time model, never layer balance or chip names.
    /// Even measured whole-model rates predict stage speed; they do not prove
    /// the selected pair/cut is measured-best. Missing rates remain explicit priors.
    public static func select(_ snapshots: [Snapshot], now: Int64) throws -> Decision {
        guard snapshots.count == 2, Set(snapshots.map(\.rank)) == Set([0, 1]) else {
            throw ClusterPlacementError("GLM automatic placement needs both rank snapshots")
        }
        let s = snapshots.sorted { $0.rank < $1.rank }
        for snapshot in s { try snapshot.validate(now: now) }
        guard s[0].commonSHA256 == s[1].commonSHA256, s[0].layout == s[1].layout else {
            throw ClusterPlacementError("GLM snapshots differ in artifact, request, policy or layout")
        }
        let cuts = Set(s[0].quotes.map(\.cut)).intersection(s[1].quotes.map(\.cut)).sorted()
        guard !cuts.isEmpty else { throw ClusterPlacementError("No GLM structural cut fits both current rank snapshots") }
        let subjects = s.map { ClusterSpeedEstimator.Subject(chip: $0.profile.chip, osBuild: $0.profile.osBuild) }
        let measurements = s.flatMap(\.measurements)
        let devices = s.enumerated().map { rank, snapshot in
            let speeds = ClusterSpeedEstimator.estimate(devices: subjects,
                artifactSHA256: snapshot.layout.artifactSHA256, runtimeBinarySHA256: snapshot.runtimeBinarySHA256,
                promptTokens: snapshot.layout.maximumPromptTokens, measurements: measurements,
                indices: s.compactMap { $0.profile.speedIndex })
            return ClusterPlacementDevice(label: "rank\(rank)", profile: snapshot.profile, speed: speeds[rank])
        }
        let shapes = cuts.map { cut in
            ClusterPlacementQuotedShape(cuts: [cut], mode: .pipeline, schedule: .serial,
                ranks: s.map { snapshot in
                    let q = snapshot.quotes.first { $0.cut == cut }!
                    return ClusterPlacementResourceQuote(nativeBytes: q.nativeBytes, hostBytes: q.hostBytes,
                        nativeAvailableBytes: snapshot.nativeAvailableBytes, hostAvailableBytes: snapshot.hostAvailableBytes,
                        combinedAvailableBytes: snapshot.combinedAvailableBytes)
                })
        }
        let ranked = try ClusterPlacementPlanner.rankQuoted(devices: devices, layout: s[0].layout, shapes: shapes)
        guard let best = ranked.first,
              ranked.allSatisfy({ $0.rested.requestSeconds.isFinite && $0.rested.requestSeconds > 0 }) else {
            throw ClusterPlacementError("GLM speed prediction is invalid")
        }
        return Decision(cut: best.cut, mode: .pipeline, feasibleCuts: cuts, rankedCuts: ranked.map(\.cut),
            prediction: best.rested, speedSources: devices.map { $0.speed.source },
            absolutePrediction: devices.allSatisfy { $0.speed.absolute },
            predictionBasis: "Existing planner; uniform layer-cost prior; unmeasured transfers counted as free",
            linkMeasured: false, measuredBestSpeed: false,
            calibratedEligible: false,
            unsupportedModes: ["tensor_parallel_v1", "pipeline_prefill_tensor_decode_v1", "phase_split", "MTP", "lookahead"])
    }

    public static func decode(_ data: Data) throws -> Snapshot {
        guard !data.isEmpty, data.count <= maximumBytes else { throw ClusterPlacementError("GLM snapshot size") }
        return try JSONDecoder().decode(Snapshot.self, from: data)
    }
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let e = JSONEncoder(); e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try e.encode(value)
        guard data.count <= maximumBytes else { throw ClusterPlacementError("GLM placement output size") }
        return data
    }

    /// Hash the original local template and the shared finite scope separately.
    /// A cut may be omitted for automatic selection. All other local choices,
    /// including bounds/environment and file pins, remain covered unchanged.
    public static func bindings(_ data: Data) throws -> (local: String, common: String) {
        guard !data.isEmpty, data.count <= 256 << 10,
              var root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              var request = root["request"] as? [String: Any],
              var selection = request["selection"] as? [String: Any],
              let authorization = request["authorization"] as? [String: Any] else {
            throw ClusterPlacementError("Expected an installed GLM quotation template")
        }
        selection.removeValue(forKey: "cut"); request["selection"] = selection; root["request"] = request
        let local = try digest(root)
        for key in ["rank", "environment", "hostAllocationQuantum", "hostAllocationOverhead"] {
            selection.removeValue(forKey: key)
        }
        var scope: [String: Any] = [:]
        for key in ["requestID", "promptTokenIDs", "outputCount", "chunkSize"] {
            guard let value = authorization[key] else { throw ClusterPlacementError("Incomplete finite request") }
            scope[key] = value
        }
        return (local, try digest(["clusterID": root["clusterID"] ?? NSNull(), "selection": selection, "request": scope]))
    }
    public static func selecting(cut: Int, in data: Data) throws -> Data {
        guard cut > 0, var root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              var request = root["request"] as? [String: Any],
              var selection = request["selection"] as? [String: Any] else { throw ClusterPlacementError("Invalid GLM template") }
        selection["cut"] = cut; request["selection"] = selection; root["request"] = request
        return try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys, .withoutEscapingSlashes])
    }
    private static func digest(_ value: Any) throws -> String {
        SHA256.hash(data: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]))
            .map { String(format: "%02x", $0) }.joined()
    }
    private static func isHash(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}
