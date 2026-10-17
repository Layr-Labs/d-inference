import Foundation
import Hummingbird

/// Capture before auth, body collection, decoding, tokenization or acquisition.
/// Task-local scope covers upstream routes too; no wall-clock/client field can
/// replace this origin. Only the distributed engine uses it for deadlines.
public struct LocalRequestOriginResponder<Inner: HTTPResponder>: HTTPResponder {
    public typealias Context = Inner.Context
    public let inner: Inner

    public init(inner: Inner) { self.inner = inner }

    public func respond(to request: Request, context: Context) async throws -> Response {
        let receivedAt = ContinuousClock.now
        return try await DistributedRequestOrigin.$current.withValue(receivedAt) {
            try await inner.respond(to: request, context: context)
        }
    }
}
