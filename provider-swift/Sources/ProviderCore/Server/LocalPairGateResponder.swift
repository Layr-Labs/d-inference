import Foundation
import HTTPTypes
import Hummingbird
import NIOCore

/// A pair's API while its pair takes no requests (no slot published yet, its warmup canary runs, it retires:
/// `LocalResponseTracker.pairRefuses`): a request that needs the pair (a POST) gets the pair's typed 503 at once
/// (`ClusterPairAPIRefusal`), from a flag read without waiting for the loop, so it is never held while the part starts or
/// the pair forms. Behind the key check (only a caller with a key gets these words), and inside the router, which passes
/// it on as any 503 of this Mac's. A pass-through on every other API.
public struct LocalPairGateResponder<Inner: HTTPResponder>: HTTPResponder {
    public typealias Context = Inner.Context
    public let inner: Inner
    let tracker: LocalResponseTracker?

    init(inner: Inner, tracker: LocalResponseTracker?) {
        self.inner = inner
        self.tracker = tracker
    }

    public func respond(to request: Request, context: Context) async throws -> Response {
        if request.method == .post, tracker?.pairRefuses == true { return ClusterPairAPIRefusal.response() }
        return try await inner.respond(to: request, context: context)
    }
}

/// What a pair's API answers while its pair doesn't serve: the 503 a member's relay answers while this API doesn't
/// listen (`ClusterLocalRelay.notAnsweringCode`, `Retry-After: 10`), in the local API's error shape, with words true on
/// every Mac of the pair (`ClusterLocalRelay.pairNotServing`), so the first request after a stop begins gets the answer
/// every later one gets.
enum ClusterPairAPIRefusal {
    static func response() -> Response {
        let error = ["code": ClusterLocalRelay.notAnsweringCode, "type": "server_error",
                     "message": ClusterLocalRelay.pairNotServing(cli: BuildEnvironment.current.cliName)]
        let body = (try? JSONSerialization.data(withJSONObject: ["error": error], options: [.sortedKeys]))
            ?? Data(#"{"error":{"message":"the pair's API takes no requests right now","type":"server_error"}}"#.utf8)
        var headers = HTTPFields()
        headers[.contentType] = "application/json"
        headers[.accessControlAllowOrigin] = "*"
        headers[.retryAfter] = "10"
        return Response(status: .serviceUnavailable, headers: headers, body: .init(byteBuffer: ByteBuffer(bytes: body)))
    }

    /// A POST a pair's API refuses at its door (`LocalDisconnectResponder`: a stop, a restart or an update drains it):
    /// the typed 503 to a caller with either of its keys, the API's own 401 to any other, as its key check would answer.
    static func admissionRefusal(token: String?, pairToken: String) -> @Sendable (Request) -> Response {
        { request in
            LocalAuthPolicy.authorize(method: request.method, path: request.uri.path,
                                      authorizationHeader: request.headers[.authorization], token: token, pairToken: pairToken)
                ? response() : LocalAuthPolicy.unauthorizedResponse()
        }
    }
}
