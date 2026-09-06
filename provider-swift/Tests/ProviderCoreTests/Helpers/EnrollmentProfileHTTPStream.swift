import Foundation

/// A per-request, in-process HTTP stream. Chunks arrive on separate queue turns;
/// `.stall` deliberately leaves EOF unsent so rejection must cancel live IO.
/// All requests in this session are intercepted, including unexpected URLs.
final class EnrollmentProfileHTTPStream: @unchecked Sendable {
    enum Ending: Sendable {
        case finish, stall
        case fail(URLError.Code)
    }

    struct Snapshot: Sendable {
        var request: URLRequest?
        var deliveredBytes = 0
        var bodySent = false
        var finished = false
        var stopped = false
    }

    let coordinatorURL: String
    let request: URLRequest
    let session: URLSession
    private let queue = DispatchQueue(label: "enrollment-profile-test-stream")
    private let lock = NSLock()
    private var state = Snapshot()
    private var connection: URLProtocol?

    init() {
        let baseURL = "https://\(UUID().uuidString.lowercased()).enrollment.invalid"
        coordinatorURL = baseURL
        request = URLRequest(
            url: URL(string: "\(baseURL)/v1/enroll")!,
            timeoutInterval: 30
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [EnrollmentProfileURLProtocol.self]
        session = URLSession(configuration: configuration)
        EnrollmentProfileURLProtocol.register(self, for: request.url!)
    }

    var snapshot: Snapshot { lock.withLock { state } }

    func close() {
        session.invalidateAndCancel()
        EnrollmentProfileURLProtocol.remove(for: request.url!)
        stop()
    }

    fileprivate func start(_ connection: URLProtocol) {
        lock.withLock {
            self.connection = connection
            state.request = connection.request
        }
    }

    fileprivate func stop() {
        lock.withLock {
            state.stopped = true
            connection = nil
        }
    }

    func sendResponse(status: Int = 200, headers: [String: String]) {
        queue.async {
            guard let connection = self.activeConnection else { return }
            let response = HTTPURLResponse(
                url: self.request.url!, statusCode: status,
                httpVersion: "HTTP/1.1", headerFields: headers
            )!
            connection.client?.urlProtocol(
                connection, didReceive: response, cacheStoragePolicy: .notAllowed
            )
        }
    }

    func sendBody(_ data: Data, ending: Ending = .finish) {
        queue.async { self.pump(data, offset: 0, ending: ending) }
    }

    func fail(_ code: URLError.Code) {
        queue.async {
            guard let connection = self.takeConnection() else { return }
            connection.client?.urlProtocol(connection, didFailWithError: URLError(code))
        }
    }

    func waitUntil(_ predicate: @Sendable (Snapshot) -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !predicate(snapshot) {
            guard ContinuousClock.now < deadline else {
                throw StreamError.eventTimedOut
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private var activeConnection: URLProtocol? {
        lock.withLock { state.stopped ? nil : connection }
    }

    private func takeConnection() -> URLProtocol? {
        lock.withLock {
            defer { connection = nil }
            return state.stopped ? nil : connection
        }
    }

    private func pump(_ data: Data, offset: Int, ending: Ending) {
        guard let connection = activeConnection else { return }
        if offset < data.count {
            let end = min(offset + 16_384, data.count)
            lock.withLock { state.deliveredBytes += end - offset }
            connection.client?.urlProtocol(connection, didLoad: data.subdata(in: offset..<end))
            queue.asyncAfter(deadline: .now() + .milliseconds(2)) {
                self.pump(data, offset: end, ending: ending)
            }
            return
        }
        lock.withLock { state.bodySent = true }
        switch ending {
        case .stall:
            break
        case .finish:
            guard let connection = takeConnection() else { return }
            lock.withLock { state.finished = true }
            connection.client?.urlProtocolDidFinishLoading(connection)
        case .fail(let code):
            guard let connection = takeConnection() else { return }
            connection.client?.urlProtocol(connection, didFailWithError: URLError(code))
        }
    }

    private enum StreamError: Error { case eventTimedOut }
}

private final class EnrollmentProfileURLProtocol: URLProtocol, @unchecked Sendable {
    private static let registryLock = NSLock()
    nonisolated(unsafe) private static var streams: [URL: EnrollmentProfileHTTPStream] = [:]
    private var stream: EnrollmentProfileHTTPStream?

    static func register(_ stream: EnrollmentProfileHTTPStream, for url: URL) {
        registryLock.withLock { streams[url] = stream }
    }

    static func remove(for url: URL) {
        _ = registryLock.withLock { streams.removeValue(forKey: url) }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        stream = Self.registryLock.withLock { request.url.flatMap { Self.streams[$0] } }
        guard let stream else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        stream.start(self)
    }

    override func stopLoading() { stream?.stop() }
}
