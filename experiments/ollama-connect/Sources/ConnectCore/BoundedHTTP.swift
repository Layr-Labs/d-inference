import Foundation

/// All networking in the companion is GET-only metadata. No prompt, inference,
/// arbitrary URL, Authorization header, cookie, or model-supplied URL is accepted.
public enum MetadataEndpoint: Sendable, CaseIterable {
    case ollamaModels, ollamaRunning, catalog, attestations

    public var url: URL {
        switch self {
        case .ollamaModels: URL(string: "http://127.0.0.1:11434/api/tags")!
        case .ollamaRunning: URL(string: "http://127.0.0.1:11434/api/ps")!
        case .catalog: URL(string: "https://api.darkbloom.dev/v1/models/catalog")!
        case .attestations: URL(string: "https://api.darkbloom.dev/v1/providers/attestation")!
        }
    }

    public var byteLimit: Int { self == .attestations ? 8_388_608 : 1_048_576 }
}

public enum ConnectError: String, Error, LocalizedError, Sendable {
    case unavailable = "The service is unavailable. Try again."
    case invalidResponse = "The service returned an invalid response."
    case oversized = "The response exceeded the metadata limit."
    case redirect = "A metadata redirect was blocked."
    case unsafeFile = "The local metadata file could not be read safely."
    case untrustedWorker = "Install the signed Darkbloom provider to continue."
    case invalidModel = "Choose a current model from the Darkbloom catalog."
    case busy = "Another action is already running."
    case commandFailed = "The provider command did not complete. Run darkbloom doctor for details."
    public var errorDescription: String? { rawValue }
}

public struct MetadataClient: Sendable {
    public init() {}
    public func get(_ endpoint: MetadataEndpoint) async throws -> Data {
        try await BoundedTransfer.fetch(endpoint)
    }
}

/// A separate delegate/session per transfer prevents cross-request state. The
/// size limit is enforced while receiving, not after buffering the whole body.
final class BoundedTransfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let endpoint: MetadataEndpoint
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data, Error>?
    private var bytes = Data()
    private var task: URLSessionDataTask?
    private var session: URLSession?
    private var finished = false

    init(_ endpoint: MetadataEndpoint) { self.endpoint = endpoint }

    static func fetch(_ endpoint: MetadataEndpoint) async throws -> Data {
        let transfer = BoundedTransfer(endpoint)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { transfer.start($0) }
        } onCancel: {
            transfer.finish(.failure(CancellationError()))
        }
    }

    private func start(_ callback: CheckedContinuation<Data, Error>) {
        lock.lock()
        guard !finished else { lock.unlock(); callback.resume(throwing: CancellationError()); return }
        continuation = callback
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        config.urlCache = nil
        config.httpShouldSetCookies = false
        config.connectionProxyDictionary = ["HTTPEnable": 0, "HTTPSEnable": 0, "SOCKSEnable": 0]
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 12
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        var request = URLRequest(url: endpoint.url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        self.session = session
        let task = session.dataTask(with: request)
        self.task = task
        lock.unlock()
        task.resume()
    }

    private func finish(_ result: Result<Data, Error>) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let callback = continuation
        continuation = nil
        let session = session
        self.session = nil
        task = nil
        lock.unlock()
        session?.invalidateAndCancel()
        callback?.resume(with: result)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            completionHandler(.performDefaultHandling, nil)
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
        finish(.failure(ConnectError.redirect))
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        guard response.url == endpoint.url,
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              response.mimeType == "application/json" else {
            completionHandler(.cancel); finish(.failure(ConnectError.invalidResponse)); return
        }
        guard response.expectedContentLength <= endpoint.byteLimit else {
            completionHandler(.cancel); finish(.failure(ConnectError.oversized)); return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        guard data.count <= endpoint.byteLimit - bytes.count else {
            lock.unlock(); finish(.failure(ConnectError.oversized)); return
        }
        bytes.append(data)
        lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock(); let result = bytes; lock.unlock()
        if error != nil { finish(.failure(ConnectError.unavailable)) }
        else { finish(.success(result)) }
    }
}
