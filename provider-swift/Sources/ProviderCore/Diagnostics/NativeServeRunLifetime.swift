import Foundation

/// The CLI must terminate its owned process on failure. An uncancellable native
/// task cannot prevent a failed observer/drain from reaching that boundary.
enum NativeServeRunLifetime {
    enum Failure: Error { case servingEndedBeforeObservation }

    private enum Event {
        case observationCompleted, servingCompleted, shutdownCompleted
        case failed(any Error)
    }

    static func run(
        serve: @escaping @Sendable () async throws -> Void,
        observe: @escaping @Sendable () async throws -> Void,
        shutdown: @escaping @Sendable () async throws -> Void
    ) async throws {
        try Task.checkCancellation()
        let (events, continuation) = AsyncStream<Event>.makeStream()
        let serving = Task {
            do {
                try Task.checkCancellation()
                try await serve()
                try Task.checkCancellation()
                continuation.yield(.servingCompleted)
            } catch { continuation.yield(.failed(error)) }
        }
        let observer = Task {
            do {
                try Task.checkCancellation()
                try await observe()
                try Task.checkCancellation()
                // Publish before starting drain: it can finish serve before
                // returning its own acknowledgement, but cannot qualify a run.
                continuation.yield(.observationCompleted)
                try await shutdown()
                try Task.checkCancellation()
                continuation.yield(.shutdownCompleted)
            } catch { continuation.yield(.failed(error)) }
        }
        defer { serving.cancel(); observer.cancel(); continuation.finish() }
        var observed = false
        var served = false
        var shutDown = false
        for await event in events {
            try Task.checkCancellation()
            switch event {
            case .observationCompleted:
                observed = true
            case .servingCompleted:
                guard observed else { throw Failure.servingEndedBeforeObservation }
                served = true
            case .shutdownCompleted:
                shutDown = true
            case .failed(let error):
                throw error
            }
            if served && shutDown { return }
        }
        throw CancellationError()
    }
}
