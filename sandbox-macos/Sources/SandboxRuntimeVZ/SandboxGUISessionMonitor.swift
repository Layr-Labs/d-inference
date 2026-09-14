/// Watches the process's own Security/audit session. A console-user lookup
/// cannot prove that this process still belongs to its original Aqua session.
public struct SandboxGUISessionMonitor: Sendable {
    private let baseline: SandboxProcessSecurityContextSnapshot
    private let capture: @Sendable () -> SandboxProcessSecurityContextSnapshot
    private let sleep: @Sendable () async throws -> Void

    public init() throws {
        try self.init(capture: { .capture() }, sleep: { try await Task.sleep(for: .seconds(1)) })
    }

    init(capture: @escaping @Sendable () -> SandboxProcessSecurityContextSnapshot,
         sleep: @escaping @Sendable () async throws -> Void) throws {
        let baseline = capture()
        guard baseline.isUsableGUISession else { throw SandboxGUISessionError.unavailable }
        self.baseline = baseline
        self.capture = capture
        self.sleep = sleep
    }

    public func run() async throws {
        while true {
            try Task.checkCancellation()
            let current = capture()
            guard current.isUsableGUISession, current.realUID == baseline.realUID,
                  current.auditUID == baseline.auditUID, current.sessionID == baseline.sessionID else {
                throw SandboxGUISessionError.changed
            }
            try await sleep()
        }
    }
}

public enum SandboxGUISessionError: Error, Sendable {
    case unavailable
    case changed
}
