import Foundation
import Hummingbird
import NIOCore

/// Preserve the actual application's channel before BasicRequestContext drops
/// it. Existing auth/router responders still receive the same basic storage.
public struct LocalConnectionRequestContext: RequestContext {
    public var coreContext: CoreRequestContextStorage
    let channel: any Channel
    public init(source: ApplicationRequestContextSource) {
        coreContext = .init(source: source); channel = source.channel
    }
}

enum LocalHTTPConnectionScope {
    @TaskLocal static var current: (any Channel)?
}

public struct LocalConnectionResponder<Inner: HTTPResponder>: HTTPResponder
where Inner.Context == BasicRequestContext {
    public typealias Context = LocalConnectionRequestContext
    let inner: Inner
    let observeConnection: Bool

    public func respond(to request: Request, context: Context) async throws -> Response {
        var basic = BasicRequestContext(source: .init(channel: context.channel, logger: context.logger))
        basic.coreContext = context.coreContext
        if !observeConnection { return try await inner.respond(to: request, context: basic) }
        let innerContext = basic
        return try await LocalHTTPConnectionScope.$current.withValue(context.channel) {
            try await inner.respond(to: request, context: innerContext)
        }
    }
}
