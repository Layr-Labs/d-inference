import Foundation
import HTTPTypes
import Hummingbird
import NIOCore

/// Bearer-token auth for the local (direct-mode) OpenAI server. Wraps the
/// upstream router so every inference route requires `Authorization: Bearer
/// <token>`, closing the "any local process / hostile webpage can use my GPU"
/// hole that an unauthenticated loopback server (with `CORS: *`) has.
///
/// Exemptions: `OPTIONS` preflights (so CORS still works) and `GET /health` /
/// `GET /` (liveness, no secret). When `token` is nil the responder is a
/// pass-through, preserving the unauthenticated behaviour for explicit
/// `--no-auth` / trusted-airgapped use and for library callers that don't opt
/// in. The 401 carries `Access-Control-Allow-Origin: *` so browser clients can
/// read the error body.
public struct LocalAuthResponder<Inner: HTTPResponder>: HTTPResponder {
    public typealias Context = Inner.Context

    public let inner: Inner
    public let token: String?

    public init(inner: Inner, token: String?) {
        self.inner = inner
        self.token = token
    }

    public func respond(to request: Request, context: Context) async throws -> Response {
        if LocalAuthPolicy.authorize(
            method: request.method,
            path: request.uri.path,
            authorizationHeader: request.headers[.authorization],
            token: token
        ) {
            return try await inner.respond(to: request, context: context)
        }
        return LocalAuthPolicy.unauthorizedResponse()
    }
}

/// The pure local-auth policy, factored out of the generic responder so it can
/// be unit-tested directly (no HTTP stack, no valid `Inner` type required).
public enum LocalAuthPolicy {
    /// Authorization decision:
    ///   * nil/empty token              → open (no auth configured)
    ///   * OPTIONS                      → allowed (CORS preflight)
    ///   * GET/HEAD /health, /v1/health, / → allowed (liveness)
    ///   * else                         → requires `Bearer <token>` (constant-time)
    static func authorize(
        method: HTTPRequest.Method,
        path: String,
        authorizationHeader: String?,
        token: String?
    ) -> Bool {
        guard let token, !token.isEmpty else { return true }
        if method == .options { return true }
        let isLiveness = path == "/health" || path == "/v1/health" || path == "/"
        if isLiveness, method == .get || method == .head { return true }
        guard let header = authorizationHeader else { return false }
        let prefix = "Bearer "
        guard header.hasPrefix(prefix) else { return false }
        let provided = String(header.dropFirst(prefix.count))
        return constantTimeEquals(provided, token)
    }

    /// Length-checked constant-time comparison. Tokens are fixed-length, so the
    /// early length check leaks nothing useful.
    static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let ab = Array(a.utf8)
        let bb = Array(b.utf8)
        guard ab.count == bb.count else { return false }
        var diff: UInt8 = 0
        for i in ab.indices { diff |= ab[i] ^ bb[i] }
        return diff == 0
    }

    static func unauthorizedResponse() -> Response {
        let body = Data(#"{"error":{"message":"missing or invalid local API key — get it from `darkbloom local`","type":"authentication_error"}}"#.utf8)
        var headers = HTTPFields()
        headers[.contentType] = "application/json"
        headers[.wwwAuthenticate] = "Bearer"
        headers[.accessControlAllowOrigin] = "*"
        return Response(status: .unauthorized, headers: headers, body: .init(byteBuffer: ByteBuffer(bytes: body)))
    }
}
