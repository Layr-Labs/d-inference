import Foundation

struct QwenResidentSoloTiming: Encodable {
    let clock = "DispatchTime.uptimeNanoseconds.same_process"
    let requestStartNanoseconds: UInt64
    let selectedTokenNanoseconds: [UInt64]
    let retiredNanoseconds: UInt64
    let prefillSeconds: Double
    let decodeSeconds: Double
    let prefillTokensPerSecond: Double
    let decodeTokensPerSecond: Double
    let includesLoading = false
    let includesSourceAndResourceAdmission = false
    let includesFreshStateConstruction = true
    let includesPerForwardOwnershipValidation = true
    let includesDiagnosticRowOrStateCapture = false
    let includesTransport = false
    let externalTTFTMeasured = false

    init(start: UInt64, selected: [UInt64], retired: UInt64) throws {
        guard selected.count == 128, let first = selected.first, let last = selected.last,
              start < first, first < last, last <= retired,
              zip(selected, selected.dropFirst()).allSatisfy({ $0 <= $1 }) else {
            throw ProbeError("Resident solo token timing order or count differs")
        }
        requestStartNanoseconds = start; selectedTokenNanoseconds = selected; retiredNanoseconds = retired
        prefillSeconds = Double(first - start) / 1e9
        decodeSeconds = Double(last - first) / 1e9
        prefillTokensPerSecond = 8192 / prefillSeconds
        decodeTokensPerSecond = 127 / decodeSeconds
    }
}

struct QwenResidentSoloRequestResult: Encodable {
    let requestID: UUID
    let requestFingerprint: String
    let selectedTokenIDs: [Int]
    let selectedTokenIDsSHA256: String
    let completedFrames: Int
    let committedTokens: Int
    let timing: QwenResidentSoloTiming
    let promptCount = 8192
    let chunkSize = 512
    let requestedOutputCount = 128
    let finishReason = "length"
    let expectedTokenSequenceMatched = true
    let allRequestStateRetired = true
    let modelRemainsResident = true
    let prefixReuse = false
    let mtpEnabled = false
    let fullVocabularyRowsCaptured = false
    let stateSnapshotsCaptured = false
    let independentFullRowStateComparisonPerformed = false
}
