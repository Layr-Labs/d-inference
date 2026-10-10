import Foundation

/// What a link fix must leave exactly as it found it: which interfaces each
/// bridge contains, and which interface carries the default route.
struct ClusterLinkTopology: Equatable, Sendable {
    /// Bridge interface name to its members, in listed order.
    let bridgeMembers: [String: [String]]
    /// Nil when this Mac has no default route.
    let defaultRouteInterface: String?

    /// Nil when either listing could not be read or recognized.
    static func observe(run: ClusterLinkToolRunner) -> ClusterLinkTopology? {
        guard case .output(let listing) = run(.interfaceList),
              let interfaces = ClusterNetworkInterfaces.parse(listing) else { return nil }
        let routeInterface: String?
        switch run(.defaultRoute) {
        case .output(let text):
            guard let interface = defaultRouteInterface(inRouteText: text) else { return nil }
            routeInterface = interface
        case .unavailable:
            // `route` exits non-zero when no default route exists.
            routeInterface = nil
        case .timedOut, .outputTooLarge:
            return nil
        }
        let bridges = interfaces.interfaces.filter { !$0.bridgeMembers.isEmpty }.map { ($0.name, $0.bridgeMembers) }
        return ClusterLinkTopology(bridgeMembers: Dictionary(bridges, uniquingKeysWith: { first, _ in first }),
            defaultRouteInterface: routeInterface)
    }

    /// The `interface:` line of `route -n get default`; nothing else is read.
    static func defaultRouteInterface(inRouteText text: String) -> String? {
        let named = text.split(whereSeparator: \.isNewline).compactMap { line -> [Substring]? in
            let words = line.split(whereSeparator: \.isWhitespace)
            return words.first == "interface:" ? Array(words.dropFirst()) : nil
        }
        guard named.count == 1, named[0].count == 1, ClusterLinkName.isInterface(String(named[0][0])) else { return nil }
        return String(named[0][0])
    }
}
