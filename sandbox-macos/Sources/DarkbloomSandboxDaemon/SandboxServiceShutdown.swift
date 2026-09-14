import SandboxRuntime

/// Once a runtime exists, every exit path must await cleanup. A cancelled
/// service cannot cancel this final stop proof or release reservations itself.
enum SandboxServiceShutdown {
    static func run(
        operation: () async throws -> Void,
        shutdown: @escaping @Sendable () async throws -> Void
    ) async throws {
        let result: Result<Void, Error>
        do {
            try Task.checkCancellation()
            try await operation()
            result = .success(())
        } catch {
            result = .failure(error)
        }
        let cleanup = Task.detached { try await shutdown() }
        do {
            try await cleanup.value
        } catch {
            let primary: String
            switch result {
            case .success: primary = "service ended"
            case .failure(let cause): primary = String(describing: cause)
            }
            throw SandboxRuntimeError.cleanupFailed(operation: "sandbox service shutdown",
                primary: primary, cleanup: String(describing: error))
        }
        try result.get()
    }
}
