import NIOCore
import Hummingbird

/// Capture transport ownership without changing the upstream router's basic
/// context, authentication, body limits, response framing, or model registry.
public struct LocalDisconnectContext: RequestContext {
    public typealias Source = ApplicationRequestContextSource
    public var coreContext: CoreRequestContextStorage
    private let base: BasicRequestContext
    let connection: LocalHTTPConnectionCancellation
    /// The application's actual channel, retained for the distributed
    /// response-observation scope; never read on the ordinary local path.
    let rawChannel: any Channel

    public init(source: Source) {
        base = BasicRequestContext(source: source)
        coreContext = base.coreContext
        connection = LocalHTTPConnectionCancellationRegistry.shared.connection(for: source.channel)
        rawChannel = source.channel
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
    /// Binds the channel into the distributed response scope for this request;
    /// false on every ordinary local engine (no behavior change).
    var observeConnection = false
    /// What a POST refused admission (a drain) gets; nil: the capacity 503. A pair's API answers its typed 503 to a caller
    /// with a key and its 401 to any other (`ClusterPairAPIRefusal.admissionRefusal`).
    var refusal: (@Sendable (Request) -> Response)? = nil

    public func respond(to request: Request, context: Context) async throws -> Response {
        let lease: LocalResponseTracker.Lease?
        do {
            lease = request.method == .post ? try responseTracker?.admit() : nil
        } catch let error as HTTPError where error.status == .serviceUnavailable {
            // Admission wraps the router's error mapper, so render this refusal
            // here before creating request or response ownership.
            if let refusal { return refusal(request) }
            return CORSResponder<Inner>.openAIErrorResponse(
                status: .serviceUnavailable,
                message: InferenceFailureCode.capacity.message)
        }
        let scope = context.connection.makeScope()
        let task = Task<Response, Error> {
            try await LocalRequestCancellation.$current.withValue(scope) {
                // A client on another machine never gets the router's paid hop (`LocalHTTPClient`).
                guard context.connection.fromAnotherMachine else { return try await respondInside(request, context) }
                return try await LocalHTTPClient.$fromAnotherMachine.withValue(true) {
                    try await respondInside(request, context)
                }
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

    private func respondInside(_ request: Request, _ context: Context) async throws -> Response {
        if observeConnection {
            return try await LocalHTTPConnectionScope.$current.withValue(context.rawChannel) {
                try await inner.respond(to: request, context: context.basic)
            }
        }
        return try await inner.respond(to: request, context: context.basic)
    }
}
