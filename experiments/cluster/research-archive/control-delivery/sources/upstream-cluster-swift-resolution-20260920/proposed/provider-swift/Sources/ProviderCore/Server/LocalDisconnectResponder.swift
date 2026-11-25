import Hummingbird
import NIOCore

/// Capture transport ownership without changing the upstream router's basic
/// context, authentication, body limits, response framing, or model registry.
public struct LocalDisconnectContext: RequestContext {
    public typealias Source = ApplicationRequestContextSource
    public var coreContext: CoreRequestContextStorage
    private let base: BasicRequestContext
    let channel: any Channel
    let connection: LocalHTTPConnectionCancellation

    public init(source: Source) {
        base = BasicRequestContext(source: source)
        coreContext = base.coreContext
        channel = source.channel
        connection = LocalHTTPConnectionCancellationRegistry.shared.connection(for: source.channel)
    }

    var basic: BasicRequestContext {
        var context = base
        context.coreContext = coreContext
        return context
    }
}

public struct LocalDisconnectResponder<Inner: HTTPResponder>: HTTPResponder
where Inner.Context == BasicRequestContext {
    public typealias Context = LocalDisconnectContext
    let inner: Inner
    let observeConnection: Bool

    init(inner: Inner, observeConnection: Bool = false) {
        self.inner = inner
        self.observeConnection = observeConnection
    }

    public func respond(to request: Request, context: Context) async throws -> Response {
        let scope = context.connection.makeScope()
        let task = Task<Response, Error> {
            try await LocalRequestCancellation.$current.withValue(scope) {
                // Only distributed HTTP retains the actual channel for its
                // owned response hold; cancellation keeps the upstream scope.
                if observeConnection {
                    return try await LocalHTTPConnectionScope.$current.withValue(context.channel) {
                        try await inner.respond(to: request, context: context.basic)
                    }
                }
                return try await inner.respond(to: request, context: context.basic)
            }
        }
        let preparation = scope.register { task.cancel() }
        defer { preparation.remove() }
        // Covers body decoding, model acquisition and media preparation.
        // Admitted native streams register their own removable row hook.
        return try await withTaskCancellationHandler {
            do {
                return try await task.value
            } catch {
                scope.cancel()
                throw error
            }
        } onCancel: {
            scope.cancel()
        }
    }
}
