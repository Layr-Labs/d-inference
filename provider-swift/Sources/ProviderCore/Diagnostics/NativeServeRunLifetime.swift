import Foundation

/// The CLI must terminate its owned process on failure. An uncancellable native
/// task cannot prevent a failed observer/drain from reaching that boundary.
enum NativeServeRunLifetime {
    static func run(
        serve: @escaping @Sendable () async throws -> Void,
        observe: @escaping @Sendable () async throws -> Void
    ) async throws {
        let (events, continuation) = AsyncStream<Result<Void, any Error>>.makeStream(bufferingPolicy: .bufferingNewest(2))
        let serving = Task {
            do { try await serve(); continuation.yield(.success(())) }
            catch { continuation.yield(.failure(error)) }
        }
        let observer = Task {
            do { try await observe(); continuation.yield(.success(())) }
            catch { continuation.yield(.failure(error)) }
        }
        defer { serving.cancel(); observer.cancel(); continuation.finish() }
        var iterator = events.makeAsyncIterator()
        guard let first = await iterator.next() else { throw CancellationError() }
        try first.get()
        // A successful observation includes an acknowledged drain. Join its
        // normal teardown; failures above deliberately require CLI process exit.
        serving.cancel()
        observer.cancel()
        await serving.value
        await observer.value
        if let second = await iterator.next() { try second.get() }
    }
}
