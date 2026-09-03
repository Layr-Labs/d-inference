// ws(s):// -> http(s):// normalization used by SelfUpdater when deriving the
// coordinator's HTTP release endpoint from its WebSocket URL.

/// Namespace for coordinator URL scheme normalization helpers.
enum WebSocketURLScheme {
    /// Convert a WebSocket URL string to its HTTP equivalent:
    /// `wss://` becomes `https://` and `ws://` becomes `http://`.
    /// Any other scheme (or a schemeless string) passes through unchanged.
    static func toHTTP(_ url: String) -> String {
        if url.hasPrefix("wss://") {
            return "https://" + url.dropFirst("wss://".count)
        }
        if url.hasPrefix("ws://") {
            return "http://" + url.dropFirst("ws://".count)
        }
        return url
    }
}
