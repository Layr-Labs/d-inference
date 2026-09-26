import Hummingbird

/// Capture transport ownership without changing the upstream router's basic
/// context, authentication, body limits, response framing, or model registry.
public struct LocalDisconnectContext: RequestContext {
    public typealias Source = ApplicationRequestContextSource
    public var coreContext: CoreRequestContextStorage
    private let base: BasicRequestContext
    let connection: LocalHTTPConnectionCancellation

    public init(source: Source) {
        base = BasicRequestContext(source: source)
        coreContext = base.coreContext
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
    var responseTracker: LocalResponseTracker? = nil

    public func respond(to request: Request, context: Context) async throws -> Response {
        let lease = request.method == .post ? try responseTracker?.admit() : nil
        let scope = context.connection.makeScope()
        let task = Task<Response, Error> {
            try await LocalRequestCancellation.$current.withValue(scope) {
                try await inner.respond(to: request, context: context.basic)
            }
        }
        let preparation = scope.register { task.cancel() }
        defer { preparation.remove() }
        // Covers body decoding, model acquisition and media preparation.
        // Admitted native streams register their own removable row hook.
        return try await withTaskCancellationHandler {
            do {
                let response = try await task.value
                return lease?.wrap(response) ?? response
            } catch {
                lease?.release()
                scope.cancel()
                throw error
            }
        } onCancel: {
            scope.cancel()
        }
    }
}
