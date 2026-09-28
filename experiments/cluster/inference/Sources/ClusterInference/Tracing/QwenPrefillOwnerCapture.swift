import Foundation

/// One selected-chunk recorder. Its eight observations remain private until
/// the complete outer request/model owner and native error checks succeed.
final class QwenPrefillOwnerCapture {
    private let output: URL
    private var recorder: QwenPrefillOwnerRecorder?
    private var failed = false
    private var published = false

    init(output: URL) throws {
        try QwenPrefillPhaseFile.preflight(output)
        self.output = output
    }

    func makeRecorder(identity: QwenPrefillOwnerIdentity) throws -> QwenPrefillOwnerRecorder {
        guard recorder == nil, !failed, !published else {
            fail()
            throw QwenPrefillOwnerError("Selected owner capture already acquired its request")
        }
        let value = QwenPrefillOwnerRecorder(identity: identity)
        recorder = value
        return value
    }

    func publishAfterOwnerSuccess() throws {
        do {
            guard !failed, !published, let recorder else {
                throw QwenPrefillOwnerError("Selected owner capture has no successful unpublished request")
            }
            try recorder.sealAfterOuterSuccess()
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
