import Foundation

enum ClusterStatusClient {
    /// Bounded fresh local HTTP observation. No DNS, redirect, remote uptime,
    /// owner launch, inference request or persistent connection is involved.
    static func observe(binding: ClusterStatusBinding, discoveryURL: URL) async throws -> ClusterLiveStatus {
        let discovery = try ClusterStatusDiscovery.read(discoveryURL)
        let nonce = UUID().uuidString.lowercased()
        let clock = ContinuousClock(), began = ContinuousClock.now
        var request = URLRequest(url: try discovery.endpoint(), cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
                                 timeoutInterval: 3)
        request.setValue(nonce, forHTTPHeaderField: ClusterStatusCodec.nonceHeader)
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        if !discovery.apiKey.isEmpty { request.setValue("Bearer \(discovery.apiKey)", forHTTPHeaderField: "Authorization") }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 3; configuration.timeoutIntervalForResource = 3
        configuration.urlCache = nil; configuration.httpCookieStorage = nil; configuration.urlCredentialStorage = nil
        configuration.connectionProxyDictionary = [:]
        let session = URLSession(configuration: configuration, delegate: ClusterStatusNoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (stream, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              http.url == request.url,
              http.value(forHTTPHeaderField: "Cache-Control")?.lowercased() == "no-store",
              response.expectedContentLength <= Int64(ClusterStatusCodec.maximumBytes) else {
            throw ClusterConfigurationError.invalid("Local cluster status was not observed")
        }
        var bytes = Data()
        for try await byte in stream {
            guard bytes.count < ClusterStatusCodec.maximumBytes, began.duration(to: clock.now) < .seconds(3) else {
                throw ClusterConfigurationError.invalid("Local cluster status exceeded its response bound")
            }
            bytes.append(byte)
        }
        let result = try ClusterStatusCodec.decode(bytes, nonce: nonce, binding: binding,
            authenticationConfigured: !discovery.apiKey.isEmpty, port: discovery.port)
        guard began.duration(to: clock.now) < .seconds(3) else {
            throw ClusterConfigurationError.invalid("Local cluster status observation expired")
        }
        return result
    }
}

private final class ClusterStatusNoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
