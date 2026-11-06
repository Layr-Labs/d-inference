import Foundation

// These are measured-data inputs, never credentials, runtime approval or live
// resource reservations. The caller verifies the referenced evidence artifacts.
struct PlacementIdentity: Codable, Hashable, Sendable {
    let modelSHA256: String
    let adapterSHA256: String
    let arithmeticProfile: String
    let transportProfile: String
    let nodeIDs: [String]
    let nativeBuildSHA256: [String]
}

struct PlacementWorkload: Codable, Hashable, Sendable {
    let sampleSHA256: String
    let promptTokens: Int
    let prefillChunkTokens: Int
    let outputTokens: Int
    let batchSize: Int
    var prefillSteps: Int { (promptTokens - 1) / prefillChunkTokens + 1 }
    var decodeSteps: Int { outputTokens - 1 }
}

enum PlacementPhase: String, Codable, Hashable, Sendable { case prefill, transition, decode }
enum PlacementStepCoverage: String, Codable, Hashable, Sendable { case everyStep, firstStep, finalStep, none }
enum PlacementCostBasis: String, Codable, Hashable, Sendable { case median, p95 }
enum PlacementResource: String, Codable, Hashable, Sendable {
    case compute0, compute1, host0, host1, link
    static func compute(_ rank: Int) -> Self { rank == 0 ? .compute0 : .compute1 }
    static func host(_ rank: Int) -> Self { rank == 0 ? .host0 : .host1 }
}

// Unique allocation identities permit tied weights to be counted once per
// node. An adapter must describe physical packed planes, not unpacked guesses.
struct PlacementWeight: Codable, Hashable, Sendable {
    let id: String
    let bytes: UInt64
}

struct PlacementOperator: Codable, Hashable, Sendable {
    let id: String
    let fixedWeightIDs: [String]
    let expertWeightIDs: [[String]] // Empty for a non-expert operator.
    let prefillCoverage: PlacementStepCoverage
    let decodeCoverage: PlacementStepCoverage
}

struct PlacementModel: Codable, Sendable {
    let weights: [PlacementWeight]
    let operators: [PlacementOperator] // Model order, used by pipeline cuts.
}

enum PlacementAssignment: Codable, Hashable, Sendable {
    case node(Int)
    case replicated
    // Exactly two rank arrays; each global expert occurs exactly once.
    // Fixed weights of this operator are replicated. Model adapters split
    // owner-only router/norm/dense work into their own operators when needed.
    case wholeExperts([[Int]])
}

enum PlacementLayout: Codable, Hashable, Sendable {
    case singleNode(Int)
    case pipeline(cut: Int)
    case wholeExperts([String: PlacementAssignment])
}

struct PlacementMemory: Codable, Hashable, Sendable {
    let evidenceSHA256: String
    let kvCacheBytes: UInt64
    let activationPeakBytes: UInt64
    let workspacePeakBytes: UInt64
    let hostStagingBytes: UInt64
    let nativeStagingBytes: UInt64
    let otherRetainedBytes: UInt64
    // All six categories must be disjoint simultaneously-live charges at the
    // admitted maximum shape. Weights are calculated from the model separately.
    var charges: [UInt64] {
        [kvCacheBytes, activationPeakBytes, workspacePeakBytes,
         hostStagingBytes, nativeStagingBytes, otherRetainedBytes]
    }
}

struct PlacementNodeObservation: Codable, Hashable, Sendable {
    let nodeID: String
    let evidenceSHA256: String
    let actualAvailableBytes: UInt64
    let minimumFreeBytes: UInt64
    let guardBytes: UInt64
    let ageNanoseconds: UInt64 // Collector age, not a remote clock subtraction.
    let onACPower: Bool
    let pressureLevel: Int
    let swapBytes: UInt64
}

struct PlacementPolicy: Codable, Hashable, Sendable {
    let maximumObservationAgeNanoseconds: UInt64
    let requiredPressureLevel: Int
    let requireACPower: Bool
    let maximumSwapBytes: UInt64
    let costBasis: PlacementCostBasis
}

enum PlacementTaskWork: Codable, Hashable, Sendable {
    case local(rank: Int, operators: [String], measurementID: String)
    case loadWeights(rank: Int, weightIDs: [String], measurementID: String)
    case transfer(source: Int, destination: Int, plaintextBytes: UInt64,
                  records: UInt64, measurementID: String)
}

struct PlacementTask: Codable, Hashable, Sendable {
    let id: String
    let step: Int
    let dependencies: [String]
    let work: PlacementTaskWork
}

struct PlacementCandidate: Codable, Sendable {
    let id: String
    let adapterRecipeSHA256: String
    let prefillLayout: PlacementLayout
    let decodeLayout: PlacementLayout
    let prefillMemory: [PlacementMemory]
    let decodeMemory: [PlacementMemory]
    let transition: PlacementTransition?
    // These are source-bound legal execution recipes from the model adapter.
    // Include preparation/first-logit agreement in prefill; decode contains the
    // remaining output steps. Every required control/data transfer is explicit.
    let prefill: [PlacementTask]
    let decode: [PlacementTask]
}

struct PlacementTransition: Codable, Sendable {
    let evidenceSHA256: String
    let kvBytes0to1: UInt64
    let kvBytes1to0: UInt64
    let memory: [PlacementMemory]
    let tasks: [PlacementTask]
    // Memory is the live handoff peak. The planner additionally charges the
    // union of both weight layouts and requires both KV allowances to coexist.
}

struct PlacementRequest: Codable, Sendable {
    let identity: PlacementIdentity
    let workload: PlacementWorkload
    let model: PlacementModel
    let nodes: [PlacementNodeObservation]
    let policy: PlacementPolicy
    let candidates: [PlacementCandidate]
}
