import Foundation

/// A release build serves only over a coordinator connection with TLS. The
/// connection uses TLS for a `wss://` or `https://` URL
/// (`CoordinatorClient.connectionParameters`, which parses the URL the same
/// way); any other URL would connect without it, so a release build refuses
/// it before a start that would register reaches the network. Development and
/// staging builds keep plain `ws://` for local test coordinators.
///
/// The hidden native-serve and App Attest qualification modes do not come
/// through here on purpose: each accepts only an exact loopback
/// `ws://127.0.0.1` harness coordinator (`NativeServeQualificationInputs`,
/// `AppAttestQualificationCommand`).
public enum CoordinatorTransportPolicy {
    public struct Refusal: Error, CustomStringConvertible, Equatable {
        public let description: String
    }

    /// The refusal for serving through `url`, or nil when it is allowed. It
    /// names only a `ws://` or `http://` scheme, never anything else of the URL
    /// (a URL without `//` would parse its host or user name as the scheme).
    public static func refusal(forServingURL url: String,
                               environment: BuildEnvironment = .current) -> String? {
        guard environment == .prod else { return nil }
        let scheme = URL(string: url)?.scheme?.lowercased()
        switch scheme {
        case "wss", "https":
            return nil
        default:
            let given = switch scheme {
            case "ws": "a ws:// URL"
            case "http": "an http:// URL"
            default: "a URL without wss:// or https://"
            }
            return "\(environment.cliName) serves only over an encrypted coordinator connection (wss:// or https://), "
                + "not \(given). Use a wss:// URL, or remove the coordinator url to use \(environment.coordinatorWebSocketURL)."
        }
    }

    public static func requireTLS(forServingURL url: String, environment: BuildEnvironment = .current) throws {
        if let refusal = refusal(forServingURL: url, environment: environment) { throw Refusal(description: refusal) }
    }
}
