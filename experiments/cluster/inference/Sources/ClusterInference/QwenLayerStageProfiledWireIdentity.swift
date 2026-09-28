import Foundation

/// An additive namespace. Neither this profile nor these hashes admit a model,
/// resource budget or transport; native owners must qualify those separately.
enum QwenLayerStageProfiledPrefillMeasurementFlow {
    static let version = 4
    static let name = "profiled_prefill_measurement_v1"
    static let selectionPolicy = "mlx_argmax_all_axes_with_finite_guard_v1"
    typealias SchedulingPolicy = QwenLayerStagePrefillMeasurementFlow.SchedulingPolicy
}

enum QwenLayerStageProfiledWireHash {
    static let agreement = "qwen-profiled-prefill-start-agreement-v1"
    static let start = "qwen-profiled-prefill-start-packet-v1"
    static let boundary = "qwen-profiled-prefill-boundary-envelope-v1"
    static let token = "qwen-profiled-prefill-first-token-packet-v1"
    static let boundaryACK = "qwen-stage-profiled-ack-v4"
    static let postStop = "qwen-profiled-prefill-post-stop-v1"

    static func fingerprint(domain: String, bytes: Data) -> String {
        sha256(Data((domain + "\n").utf8) + bytes)
    }
}

/// Only local admitted history supplies receive geometry. A header is compared
/// to these values before a future native owner posts any payload receive.
struct QwenLayerStageProfiledBoundaryWireExpectation {
    static let maximumPayloadBytes = 16 * 1024 * 1024
    let profile: QwenLayerStagePrefillProfile
    let profileFingerprint: String
    let requestFingerprint: String
    let recordedRequestFingerprint: String
    let sourceIdentity: QwenLayerStageWireSourceIdentity
    let frame: QwenLayerStageFrame
    let tokenIDsSHA256: String
    let shape: [Int]
    let dtype: String
    let byteCount: Int

    init(request: QwenLayerStageProfiledPrefillRecordedRequest, frame: QwenLayerStageFrame,
         sourceIdentity: QwenLayerStageWireSourceIdentity, hiddenSize: Int, nativeDType: String) throws {
        let profile = request.request.profile
        guard (1...profile.maximumHiddenSize).contains(hiddenSize),
              (0..<request.steps.count).contains(frame.sequence),
              frame.sequence < profile.maximumPrefillFrames,
              request.steps[frame.sequence].frame == frame, frame.phase == .prefill else {
            throw ProbeError("Profiled boundary must be an exact frame of locally admitted token history")
        }
        let step = request.steps[frame.sequence]
        guard step.tokenIDs.count == frame.tokenCount, step.committedTokens <= request.request.promptCount else {
            throw ProbeError("Profiled boundary token slice differs from its local frontier")
        }
        let elementBytes = try qwenStageWireElementBytes(nativeDType)
        let (elements, elementOverflow) = frame.tokenCount.multipliedReportingOverflow(by: hiddenSize)
        let (bytes, byteOverflow) = elements.multipliedReportingOverflow(by: elementBytes)
        guard !elementOverflow, !byteOverflow, (1...Self.maximumPayloadBytes).contains(bytes) else {
            throw ProbeError("Profiled boundary exceeds its checked 16 MiB native payload limit")
        }
        self.profile = profile; self.profileFingerprint = profile.fingerprint
        self.requestFingerprint = request.request.fingerprint; self.recordedRequestFingerprint = request.fingerprint
        self.sourceIdentity = sourceIdentity; self.frame = frame
        self.tokenIDsSHA256 = sha256(Data(step.tokenIDs.map(String.init).joined(separator: ",").utf8))
        self.shape = [1, frame.tokenCount, hiddenSize]; self.dtype = nativeDType; self.byteCount = bytes
    }
}
