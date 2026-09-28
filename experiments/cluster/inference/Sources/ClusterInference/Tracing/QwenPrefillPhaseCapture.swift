import Foundation

/// The caller completes all native error checks inside execute. Publication
/// follows its successful return; every throwing path poisons the recorder.
func withQwenPrefillPhaseCapture<Result>(output: URL?,
    execute: (QwenPrefillPhaseCapture?) throws -> Result
) throws -> Result {
    let capture = try output.map { try QwenPrefillPhaseCapture(output: $0) }
    do {
        let result = try execute(capture)
        try capture?.publishAfterOwnerSuccess()
        return result
    } catch {
        capture?.fail()
        throw error
    }
}

/// Owns one optional request recorder and publishes only after the surrounding
/// loaded-model owner succeeds. No trace file is opened during inference.
final class QwenPrefillPhaseCapture {
    private let output: URL
    private var recorder: QwenPrefillPhaseRecorder?
    private var failed = false
    private var published = false

    init(output: URL) throws {
        try QwenPrefillPhaseFile.preflight(output)
        self.output = output
    }

    func makeRecorder(identity: QwenPrefillPhaseIdentity) throws -> QwenPrefillPhaseRecorder {
        guard recorder == nil, !failed, !published else {
            fail()
            throw QwenPrefillPhaseError("Phase capture already acquired its request owner")
        }
        let value = try QwenPrefillPhaseRecorder(identity: identity)
        recorder = value
        return value
    }

    /// Call only after the outer model owner returned and its native error box
    /// was checked. The trace itself still makes no model-release assertion.
    func publishAfterOwnerSuccess() throws {
        do {
            guard !failed, !published, let recorder else {
                throw QwenPrefillPhaseError("Phase capture has no successful unpublished owner")
            }
            let trace = try recorder.successfulTrace()
            try QwenPrefillPhaseFile.write(trace, to: output)
            published = true
        } catch {
            fail()
            throw error
        }
    }

    func fail() {
        failed = true
        recorder?.fail()
    }
}
