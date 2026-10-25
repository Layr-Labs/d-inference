import DarkbloomClusterProtocol
import Foundation

/// One ordered two-rank split's complete request reservations, rank by rank
/// (collective scratch excluded, as in `ClusterTensorParallelRequestAllowance`):
/// each rank's own heads, rows and input columns as its LOAD derives them.
/// `[1, 1]` names the equal split.
public struct ClusterPlacementTensorRankQuote: Codable, Equatable, Sendable {
    public let shares: [Int]
    public let requestBytesExcludingCollectives: [Int]

    public init(shares: [Int], requestBytesExcludingCollectives: [Int]) {
        self.shares = shares; self.requestBytesExcludingCollectives = requestBytesExcludingCollectives
    }
}

/// A registered Qwen TP row's exact native batch LOAD reservation (dense and
/// routed-expert rows alike, each priced by its own geometry). The allowance
/// is the whole-model figure either rank stays under; `rankQuotes`, when
/// present, are what each rank actually reserves under each supported split.
/// Separate from the pipeline's whole-model per-lane state. Header-only
/// native derivation supplies the allocator bound; this value never grants
/// capacity or scales a measured single-request rate.
public struct ClusterPlacementTensorBatchQuote: Codable, Equatable, Sendable {
    public static let schemaName = "darkbloom_cluster_placement_tensor_batch_quote_v1"
    /// Older readers must refuse an assistant quote instead of silently
    /// dropping its additional resident/LOAD charge.
    public static let assistantSchemaName = "darkbloom_cluster_placement_tensor_assistant_quote_v1"
    public static let maximumEncodedBytes = 32_768
    /// The rows whose owner serves request-owned TP lanes at every capacity.
    public static let runtimeModelIDs = ClusterRuntimeAdapter.qwenTensorParallelRuntimeModelIDs
    public let schema: String
    public let request: ClusterPlacementRequestScope
    public let lanes: Int
    public let chunkTokens: Int
    public let perLaneStateBytes: Int
    public let sharedBytesExcludingCollectives: Int
    public let allowance: ClusterTensorParallelRequestAllowance
    public let assistant: ClusterPlacementTensorAssistantQuote?
    /// Every supported split, the equal one included; nil prices each rank
    /// at the whole-model allowance.
    public let rankQuotes: [ClusterPlacementTensorRankQuote]?

    public init(request: ClusterPlacementRequestScope, lanes: Int, chunkTokens: Int,
                perLaneStateBytes: Int, sharedBytesExcludingCollectives: Int,
                allowance: ClusterTensorParallelRequestAllowance,
                assistant: ClusterPlacementTensorAssistantQuote? = nil,
                rankQuotes: [ClusterPlacementTensorRankQuote]? = nil) throws {
        schema = assistant == nil ? Self.schemaName : Self.assistantSchemaName; self.request = request; self.lanes = lanes; self.chunkTokens = chunkTokens
        self.perLaneStateBytes = perLaneStateBytes
        self.sharedBytesExcludingCollectives = sharedBytesExcludingCollectives; self.allowance = allowance
        self.assistant = assistant; self.rankQuotes = rankQuotes
        try validate()
    }

    public func validate() throws {
        try request.validate()
        try assistant?.validate()
        let state = perLaneStateBytes.multipliedReportingOverflow(by: lanes)
        let total = state.partialValue.addingReportingOverflow(sharedBytesExcludingCollectives)
        guard schema == (assistant == nil ? Self.schemaName : Self.assistantSchemaName),
              Self.runtimeModelIDs.contains(request.runtimeModelID),
              [1, 2, 4, 8].contains(lanes), (1...512).contains(chunkTokens), perLaneStateBytes > 0,
              sharedBytesExcludingCollectives > 0, !state.overflow, !total.overflow,
              total.partialValue == allowance.requestBytesExcludingCollectives,
              allowance.maximumContextTokens == request.maximumContextTokens,
              allowance.maximumChunkTokens == 512,
              allowance.reservedBytes <= ClusterWorkerLimits.capacityBytes else {
            throw ClusterPlacementError("Invalid Qwen tensor batch quote identity, width or full LOAD allowance")
        }
        if let rankQuotes {
            // A rank never reserves more than the whole-model figure, and
            // each split is quoted once, in whole two-rank weights.
            let splits = rankQuotes.map(\.shares)
            guard (1...8).contains(rankQuotes.count), Set(splits).count == splits.count, splits.contains([1, 1]),
                  splits.allSatisfy({ $0.count == 2 && $0.allSatisfy { (1...64).contains($0) }
                                      && (Set($0).count > 1 || $0 == [1, 1]) }),
                  rankQuotes.allSatisfy({ $0.requestBytesExcludingCollectives.count == 2
                      && $0.requestBytesExcludingCollectives.allSatisfy { (1...allowance.requestBytesExcludingCollectives).contains($0) } })
            else {
                throw ClusterPlacementError("Invalid Qwen tensor rank quotes")
            }
        }
    }

    /// What `rank` reserves at LOAD under ordered `shares` (nil or equal
    /// weights: the equal split), collective scratch included; nil when this
    /// quote prices no rank of that split.
    public func rankReservedBytes(rank: Int, shares: [Int]?) -> Int? {
        let split = shares.map { Set($0).count > 1 ? $0 : [1, 1] } ?? [1, 1]
        guard let entry = rankQuotes?.first(where: { $0.shares == split }),
              entry.requestBytesExcludingCollectives.indices.contains(rank) else { return nil }
        return entry.requestBytesExcludingCollectives[rank] + allowance.collectiveScratchBytes
    }

    public func requireRequest(promptTokens: Int, outputTokens: Int, lanes: Int, chunkTokens: Int) throws {
        guard request.promptTokens == promptTokens, request.outputTokens == outputTokens,
              self.lanes == lanes, self.chunkTokens == chunkTokens else {
            throw ClusterPlacementError("The tensor batch quote changed its requested scope, width or chunk")
        }
    }

    /// Initial automatic placement prices the same request-owned singleton;
    /// it must not manufacture a concurrent scope or use the old scalar floor.
    public func applySingleton(to policy: inout ClusterPlacementPolicy, layout: ClusterModelLayout) throws {
        try validate(layout: layout)
        guard lanes == 1,
              policy.modes == nil || policy.modes == [.tensorParallel],
              policy.schedules == nil || policy.schedules == [.serial],
              policy.forcedMode == nil, !policy.handOffModes else {
            throw ClusterPlacementError("Singleton tensor placement requires its complete serial tensor quote")
        }
        try request.applyCovering(to: &policy, layout: layout)
        policy.modes = [.tensorParallel]; policy.schedules = [.serial]
        policy.tensorParallelBatchQuote = self
    }

    /// Initial automatic placement of a row whose other modes stay
    /// admissible: tensor parallel is priced by this request-owned singleton
    /// (what its owner reserves at LOAD), every other mode as before. Only a
    /// plain target quote; an assistant's binds the placement to its mode.
    public func applySingletonCandidate(to policy: inout ClusterPlacementPolicy, layout: ClusterModelLayout) throws {
        try validate(layout: layout)
        guard lanes == 1, assistant == nil, policy.modes?.contains(.tensorParallel) ?? true,
              policy.forcedMode == nil || policy.forcedMode == .tensorParallel else {
            throw ClusterPlacementError("A singleton tensor candidate requires its plain serial tensor quote")
        }
        try request.applyCovering(to: &policy, layout: layout)
        policy.tensorParallelBatchQuote = self
    }

    public func requireAssistant(_ expected: ClusterQwenTensorAssistantPolicy?) throws {
        guard assistant?.policy == expected else {
            throw ClusterPlacementError("Tensor quotation changed the saved assistant policy")
        }
    }

    func validate(layout: ClusterModelLayout) throws {
        try validate()
        guard request.runtimeModelID == layout.runtimeModelID, request.artifactSHA256 == layout.artifactSHA256,
              request.configurationSHA256 == layout.configurationSHA256,
              let tp = layout.tensorParallel else {
            throw ClusterPlacementError("The tensor batch quote describes another model or layout")
        }
        try allowance.validate(layout: layout, partialBytesPerToken: tp.family.partialBytesPerToken)
        if let scalar = tp.family.requestAllowance {
            guard allowance.reservedBytes >= scalar.reservedBytes else {
                throw ClusterPlacementError("The tensor batch quote is smaller than the native singleton allowance")
            }
        }
    }

    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= maximumEncodedBytes else { throw ClusterPlacementError("Tensor batch quote is too large") }
        // Preserve integer spelling and duplicate keys until the strict
        // scanner has seen them. Pretty JSON is normalized only outside strings.
        var scan = Data(), quoted = false, escaped = false
        for byte in data {
            if quoted {
                scan.append(byte)
                if escaped { escaped = false }
                else if byte == 92 { escaped = true }
                else if byte == 34 { quoted = false }
            } else {
                if byte == 34 { quoted = true }
                scan.append([9, 10, 13].contains(byte) ? 32 : byte)
            }
        }
        scan.append(10)
        try validateClusterWorkerEnvelope(scan, commandStream: true)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        if let quotes = object?["rankQuotes"] {
            guard let entries = quotes as? [[String: Any]],
                  entries.allSatisfy({ Set($0.keys) == ["shares", "requestBytesExcludingCollectives"] }) else {
                throw ClusterPlacementError("Unknown or malformed tensor rank quote fields")
            }
        }
        if let object, object["assistant"] != nil {
            guard Set(object.keys).subtracting(["rankQuotes"]) == ["schema", "request", "lanes", "chunkTokens",
                "perLaneStateBytes", "sharedBytesExcludingCollectives", "allowance", "assistant"],
                  let assistant = object["assistant"] as? [String: Any],
                  Set(assistant.keys) == ["policy", "residentBytes", "loadBytes", "largestAllocationBytes"],
                  let policy = assistant["policy"] as? [String: Any] else {
                throw ClusterPlacementError("Unknown or malformed tensor assistant quote fields")
            }
            _ = try ClusterQwenTensorAssistantPolicy.decodeObject(policy)
        }
        let value = try JSONDecoder().decode(Self.self, from: data)
        try value.validate(); return value
    }
}
