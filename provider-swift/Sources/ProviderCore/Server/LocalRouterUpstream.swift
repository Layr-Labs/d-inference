import Foundation
import NIOCore
import NIOFoundationCompat

/// One request the router sends to the coordinator.
public struct LocalRouterUpstreamRequest: Sendable {
    public var url: URL
    public var method: String
    /// Every header sent; nothing of the client's is forwarded but its `Content-Type` and `Accept`.
    public var headers: [String: String]
    public var body: ByteBuffer?
    /// Until the request is on the wire (its body sent) for a request with a body, else until the response head.
    public var connectTimeout: Duration
    /// The longest time without a byte from the coordinator, the head included: `self` may queue for 120 s first.
    public var idleTimeout: Duration

    public init(url: URL, method: String, headers: [String: String], body: ByteBuffer?, connectTimeout: Duration,
                idleTimeout: Duration) {
        self.url = url
        self.method = method
        self.headers = headers
        self.body = body
        self.connectTimeout = connectTimeout
        self.idleTimeout = idleTimeout
    }
}

/// The coordinator's answer: its head, then its body as it arrives.
public struct LocalRouterUpstreamResponse: Sendable {
    public var status: Int
    /// Lower-cased names.
    public var headers: [String: String]
    public var body: AsyncThrowingStream<ByteBuffer, Error>
    /// Stops the request at the coordinator.
    public var cancel: @Sendable () -> Void

    public init(status: Int, headers: [String: String], body: AsyncThrowingStream<ByteBuffer, Error>,
                cancel: @escaping @Sendable () -> Void = {}) {
        self.status = status
        self.headers = headers
        self.body = body
        self.cancel = cancel
    }
}

public enum LocalRouterUpstreamError: Error, Equatable, CustomStringConvertible {
    case connectTimedOut
    case unreachable(String)

    public var description: String {
        switch self {
        case .connectTimedOut: return "Darkbloom did not answer the connection in time"
        case .unreachable(let reason): return reason
        }
    }
}

/// How the router reaches the coordinator. Tests substitute a stub; the product uses `URLSessionLocalRouterTransport`.
public protocol LocalRouterTransport: Sendable {
    /// Returns once the response head arrives. Cancelling the calling task, or ending iteration of the body, cancels
    /// the request.
    func send(_ request: LocalRouterUpstreamRequest) async throws -> LocalRouterUpstreamResponse
}

/// The product transport: one ephemeral `URLSession` (no cookies, no cache, no credential storage), created with the
/// router's first upstream request. Body chunks are handed on as they arrive, so a streamed answer is never held back.
public final class URLSessionLocalRouterTransport: LocalRouterTransport, @unchecked Sendable {
    private let session: URLSession

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.waitsForConnectivity = false
        // No total cap: a stream ends when the coordinator ends it. The idle limit is per request.
        configuration.timeoutIntervalForResource = 7 * 24 * 3600
        session = URLSession(configuration: configuration)
    }

    deinit { session.invalidateAndCancel() }

    public func send(_ request: LocalRouterUpstreamRequest) async throws -> LocalRouterUpstreamResponse {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method
        urlRequest.timeoutInterval = Self.seconds(request.idleTimeout)
        for (name, value) in request.headers { urlRequest.setValue(value, forHTTPHeaderField: name) }
        if let body = request.body { urlRequest.httpBody = Data(buffer: body) }

        let handler = UpstreamTaskHandler()
        let task = session.dataTask(with: urlRequest)
        task.delegate = handler
        handler.task = task
        let hasBody = request.body.map { $0.readableBytes > 0 } ?? false
        let connectTimeout = request.connectTimeout
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                handler.headContinuation = continuation
                task.resume()
                // URLSession has no connect timeout of its own, and its idle timer must allow `self`'s queueing.
                // A request whose body has not left this Mac by then never reached the coordinator.
                Task { [weak task, weak handler] in
                    try? await Task.sleep(for: connectTimeout)
                    guard let task, let handler, !handler.receivedHead,
                          !hasBody || task.countOfBytesSent == 0 else { return }
                    handler.fail(LocalRouterUpstreamError.connectTimedOut)
                    task.cancel()
                }
            }
        } onCancel: {
            task.cancel()
        }
    }

    private static func seconds(_ duration: Duration) -> TimeInterval {
        let (seconds, attoseconds) = duration.components
        return TimeInterval(seconds) + TimeInterval(attoseconds) / 1e18
    }
}

/// One upstream request's delegate: resumes the head once, then yields each body chunk as URLSession delivers it.
private final class UpstreamTaskHandler: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    var headContinuation: CheckedContinuation<LocalRouterUpstreamResponse, Error>? {
        get { lock.withLock { _head } }
        set { lock.withLock { _head = newValue } }
    }
    weak var task: URLSessionDataTask?
    private var _head: CheckedContinuation<LocalRouterUpstreamResponse, Error>?
    private var _receivedHead = false
    private var failure: Error?
    private let body: AsyncThrowingStream<ByteBuffer, Error>
    private let continuation: AsyncThrowingStream<ByteBuffer, Error>.Continuation

    var receivedHead: Bool { lock.withLock { _receivedHead } }

    override init() {
        (body, continuation) = AsyncThrowingStream<ByteBuffer, Error>.makeStream()
        super.init()
        continuation.onTermination = { [weak self] termination in
            // The relay stopped reading (the client left): stop the upstream request too.
            if case .cancelled = termination { self?.task?.cancel() }
        }
    }

    /// Fails the head (a connect timeout), keeping that reason over the cancellation that follows.
    func fail(_ error: Error) {
        let pending: CheckedContinuation<LocalRouterUpstreamResponse, Error>? = lock.withLock {
            guard !_receivedHead else { return nil }
            failure = error
            _receivedHead = true
            defer { _head = nil }
            return _head
        }
        pending?.resume(throwing: error)
        continuation.finish(throwing: error)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            return
        }
        var headers: [String: String] = [:]
        for (name, value) in http.allHeaderFields {
            if let name = name as? String, let value = value as? String { headers[name.lowercased()] = value }
        }
        let pending: CheckedContinuation<LocalRouterUpstreamResponse, Error>? = lock.withLock {
            guard !_receivedHead else { return nil }
            _receivedHead = true
            defer { _head = nil }
            return _head
        }
        completionHandler(.allow)
        pending?.resume(returning: LocalRouterUpstreamResponse(status: http.statusCode, headers: headers, body: body))
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        continuation.yield(ByteBuffer(data: data))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        // Never follow: the account key must reach only the configured coordinator.
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let (pending, earlier): (CheckedContinuation<LocalRouterUpstreamResponse, Error>?, Error?) = lock.withLock {
            let pending = _receivedHead ? nil : _head
            _receivedHead = true
            _head = nil
            return (pending, failure)
        }
        let reason = earlier ?? error.map(Self.plain)
        if let pending { pending.resume(throwing: reason ?? LocalRouterUpstreamError.unreachable("no answer")) }
        if let reason { continuation.finish(throwing: reason) } else { continuation.finish() }
    }

    /// URLSession's error in plain words, without its user-info (which names the URL).
    private static func plain(_ error: Error) -> Error {
        if error is CancellationError { return error }
        let code = (error as? URLError)?.code
        switch code {
        case .cancelled?: return CancellationError()
        case .timedOut?: return LocalRouterUpstreamError.unreachable("Darkbloom stopped answering (timed out)")
        case .cannotFindHost?, .dnsLookupFailed?: return LocalRouterUpstreamError.unreachable("Darkbloom's address could not be found")
        case .cannotConnectToHost?: return LocalRouterUpstreamError.unreachable("Darkbloom refused the connection")
        case .notConnectedToInternet?: return LocalRouterUpstreamError.unreachable("this Mac is offline")
        case .networkConnectionLost?: return LocalRouterUpstreamError.unreachable("the connection to Darkbloom was lost")
        case .secureConnectionFailed?, .serverCertificateUntrusted?, .serverCertificateHasBadDate?,
             .serverCertificateNotYetValid?, .serverCertificateHasUnknownRoot?:
            return LocalRouterUpstreamError.unreachable("Darkbloom's secure connection failed")
        default:
            return LocalRouterUpstreamError.unreachable("Darkbloom could not be reached")
        }
    }
}
