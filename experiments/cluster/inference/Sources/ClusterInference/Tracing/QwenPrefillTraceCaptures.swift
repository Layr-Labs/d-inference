import Foundation

/// Optional independent trace schemas share only the final publication gate.
/// A write failure can retain an earlier sidecar; the process still fails and
/// neither file alone is evidence of a successful native invocation.
func withQwenPrefillTraceCaptures<Result>(phaseOutput: URL?, ownerOutput: URL?,
    execute: (QwenPrefillPhaseCapture?, QwenPrefillOwnerCapture?) throws -> Result
) throws -> Result {
    if let phaseOutput, let ownerOutput,
       phaseOutput.standardizedFileURL == ownerOutput.standardizedFileURL {
        throw QwenPrefillOwnerError("Phase and selected owner traces require distinct new paths")
    }
    let phase = try phaseOutput.map { try QwenPrefillPhaseCapture(output: $0) }
    let owner = try ownerOutput.map { try QwenPrefillOwnerCapture(output: $0) }
    do {
        let result = try execute(phase, owner)
        try phase?.publishAfterOwnerSuccess()
        try owner?.publishAfterOwnerSuccess()
        return result
    } catch {
        phase?.fail()
        owner?.fail()
        throw error
    }
}
