import Foundation

/// A release build serves only over a coordinator connection with TLS. The
/// connection uses TLS for a `wss://` or `https://` URL
/// (`CoordinatorClient.connectionParameters`); any other URL would connect
/// without it, so a release build refuses it for serving. Development and
/// staging builds keep plain `ws://` for local test coordinators.
public enum CoordinatorTransportPolicy {
    public struct Refusal: Error, CustomStringConvertible, Equatable {
        public let description: String
    }

    /// The refusal for serving through `url`, or nil when it is allowed.
    public static func refusal(forServingURL url: String,
                               environment: BuildEnvironment = .current) -> String? {
        guard environment == .prod else { return nil }
        switch URL(string: url)?.scheme?.lowercased() {
        case "wss", "https":
            return nil
        default:
            return "\(environment.cliName) serves only over a TLS coordinator connection (wss://); "
                + "not \(url.isEmpty ? "an empty coordinator URL" : url). "
                + "Use a wss:// URL, or remove the coordinator url to use \(environment.coordinatorWebSocketURL)."
        }
    }

    public static func requireTLS(forServingURL url: String, environment: BuildEnvironment = .current) throws {
        if let refusal = refusal(forServingURL: url, environment: environment) { throw Refusal(description: refusal) }
    }
}
