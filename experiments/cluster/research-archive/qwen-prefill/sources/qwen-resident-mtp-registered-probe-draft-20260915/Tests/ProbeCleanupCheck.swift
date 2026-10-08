import Foundation

// Actual private cleanup method extracted verbatim. These objects only model
// throwing cleanup callbacks; no MLX, request state, or physical fence is used.
private final class CleanupLog { var calls = [String]() }
private final class CleanupOwner {
    let log: CleanupLog, fail: Bool
    init(_ log: CleanupLog, fail: Bool) { self.log = log; self.fail = fail }
    func retire(failed: Bool) throws {
        log.calls.append("owner")
        if fail { throw ProbeError("assistant-failure") }
    }
}
private final class QwenLayerStageSession {
    let log: CleanupLog, fail: Bool
    init(_ log: CleanupLog, fail: Bool) { self.log = log; self.fail = fail }
    func cancel() throws {
        log.calls.append("target")
        if fail { throw ProbeError("target-failure") }
    }
}
private final class ExtractedProbeCleanup {
    let owner: CleanupOwner?
    init(_ owner: CleanupOwner?) { self.owner = owner }
    func cancel(session: QwenLayerStageSession?, primary: Error) throws {
        var failures = [String]()
        do { try owner?.retire(failed: true) }
        catch { failures.append("assistant owner: \(error)") }
        // The request owner normally cancels its target too, but its failure
        // must not skip this independently owned driver cleanup obligation.
        do { try session?.cancel() }
        catch { failures.append("target session: \(error)") }
        guard failures.isEmpty else {
            throw ProbeError("Generation failed (\(primary)); local retirement also failed (\(failures.joined(separator: "; ")))")
        }
    }

}

enum ProbeCleanupCheck {
    static func run() throws -> Int {
        var count = 0
        for ownerFails in [false, true] {
            for targetFails in [false, true] {
                let log = CleanupLog()
                let owner = CleanupOwner(log, fail: ownerFails)
                let session = QwenLayerStageSession(log, fail: targetFails)
                var caught: Error?
                do { try ExtractedProbeCleanup(owner).cancel(session: session, primary: ProbeError("original-native-primary")) }
                catch { caught = error }
                guard log.calls == ["owner", "target"], (caught != nil) == (ownerFails || targetFails) else {
                    throw ProbeError("Cleanup did not attempt both independent obligations")
                }
                if let caught {
                    let message = String(describing: caught)
                    guard message.contains("original-native-primary"),
                          !ownerFails || message.contains("assistant-failure"),
                          !targetFails || message.contains("target-failure") else {
                        throw ProbeError("Cleanup replaced the primary or omitted a cleanup failure")
                    }
                }
                count += 1
            }
        }
        let log = CleanupLog()
        try ExtractedProbeCleanup(nil).cancel(session: QwenLayerStageSession(log, fail: false), primary: ProbeError("primary"))
        guard log.calls == ["target"] else { throw ProbeError("Missing assistant skipped target cleanup") }
        return count + 1
    }
}
