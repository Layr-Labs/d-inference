import Foundation

final class ModelDownloadURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var bodies: [String: Data] = [:]
    nonisolated(unsafe) static var requests: [URLRequest] = []
    nonisolated(unsafe) static var failure: URLError.Code?
    nonisolated(unsafe) static var pathFailures: [String: URLError.Code] = [:]
    private static let lock = NSLock()

    static func reset(bodies: [String: Data], failure: URLError.Code? = nil, pathFailures: [String: URLError.Code] = [:]) {
        lock.lock(); defer { lock.unlock() }
        self.bodies = bodies; self.failure = failure; self.pathFailures = pathFailures; requests = []
    }

    static func captured() -> [URLRequest] {
        lock.lock(); defer { lock.unlock() }; return requests
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        Self.lock.lock()
        Self.requests.append(request)
        let body = Self.bodies[url.path] ?? Self.bodies[url.host!]
        let failure = Self.pathFailures[url.path] ?? (url.host == "huggingface.co" ? Self.failure : nil)
        Self.lock.unlock()
        if let failure {
            client?.urlProtocol(self, didFailWithError: URLError(failure))
            return
        }
        var status = body == nil ? 404 : 200
        var payload = body
        var headers = ["Content-Length": "\(body?.count ?? 0)"]
        if let body, let range = request.value(forHTTPHeaderField: "Range"),
           range.hasPrefix("bytes="), let offset = Int(range.dropFirst(6).dropLast()),
           offset < body.count {
            payload = Data(body.dropFirst(offset))
            status = 206
            headers["Content-Range"] = "bytes \(offset)-\(body.count - 1)/\(body.count)"
            headers["Content-Length"] = "\(body.count - offset)"
        }
        let response = HTTPURLResponse(url: url, statusCode: status,
            httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if let payload { client?.urlProtocol(self, didLoad: payload) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
