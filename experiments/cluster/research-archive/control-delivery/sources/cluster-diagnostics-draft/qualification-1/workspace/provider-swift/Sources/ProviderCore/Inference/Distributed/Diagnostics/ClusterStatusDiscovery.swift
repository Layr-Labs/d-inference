import Foundation
import Darwin

/// Discovery locates a listener, not a process or a ready model. Credentials are
/// sent only to a numeric address assigned to this Mac (or its loopback).
struct ClusterStatusDiscovery: Decodable, Sendable {
    let baseURL: String
    let apiKey: String
    let host: String
    let port: UInt16
    private enum CodingKeys: String, CodingKey { case baseURL = "base_url", apiKey = "api_key", host, port }

    static func read(_ url: URL) throws -> Self {
        let data = try ClusterConfigurationFiles.read(url, maximum: 8192, privateMode: true)
        return try JSONDecoder().decode(Self.self, from: data)
    }

    func endpoint(localAddresses: Set<String> = Self.localAddresses()) throws -> URL {
        guard port > 0, apiKey.utf8.count <= 512,
              apiKey.utf8.allSatisfy({ (33...126).contains($0) }),
              host.utf8.count <= 128 else {
            throw ClusterConfigurationError.invalid("Malformed local endpoint discovery")
        }
        let advertised = host == "0.0.0.0" || host.isEmpty ? "127.0.0.1" : host
        // Match the exact existing LocalEndpoint.Info constructor. No URL from
        // discovery is used directly, and paths/userinfo/query are never honored.
        guard baseURL == "http://\(advertised):\(port)/v1" else {
            throw ClusterConfigurationError.invalid("Local discovery host, port and URL differ")
        }
        let dialHost: String
        switch host {
        case "", "0.0.0.0", "localhost": dialHost = "127.0.0.1"
        case "::": dialHost = "::1"
        default:
            guard let numeric = Self.numericAddress(host), localAddresses.contains(numeric) else {
                throw ClusterConfigurationError.invalid("Discovered address is not assigned to this Mac")
            }
            dialHost = numeric
        }
        var components = URLComponents()
        components.scheme = "http"; components.host = dialHost.contains(":") ? "[\(dialHost)]" : dialHost
        components.port = Int(port); components.path = "/v1/cluster/status"
        guard let url = components.url else { throw ClusterConfigurationError.invalid("Malformed local status URL") }
        return url
    }

    static func numericAddress(_ text: String) -> String? {
        var v4 = in_addr(), v6 = in6_addr()
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        if inet_pton(AF_INET, text, &v4) == 1 {
            guard inet_ntop(AF_INET, &v4, &buffer, socklen_t(buffer.count)) != nil else { return nil }
        } else if inet_pton(AF_INET6, text, &v6) == 1 {
            guard inet_ntop(AF_INET6, &v6, &buffer, socklen_t(buffer.count)) != nil else { return nil }
        } else { return nil }
        return String(cString: buffer)
    }

    static func localAddresses() -> Set<String> {
        var result: Set<String> = ["127.0.0.1", "::1"]
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0 else { return result }
        defer { freeifaddrs(first) }
        var current = first
        while let value = current {
            defer { current = value.pointee.ifa_next }
            guard let address = value.pointee.ifa_addr,
                  [AF_INET, AF_INET6].contains(Int32(address.pointee.sa_family)) else { continue }
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &buffer,
                socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            if let numeric = numericAddress(String(cString: buffer)) { result.insert(numeric) }
        }
        return result
    }
}
