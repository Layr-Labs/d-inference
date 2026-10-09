import Foundation

extension ClusterLinkReadinessReport.Device {
    /// The verdict and the observed facts behind it on one line, names only.
    var summary: String {
        var facts = [verdict.rawValue, portActive ? "port active" : "port down"]
        if let bridge { facts.append("member of \(bridge)") }
        if portActive {
            switch interfaceHasIPv4Address {
            case true?: facts.append("own IPv4 address")
            case false?: facts.append("no IPv4 address of its own")
            case nil: facts.append(interface == nil ? "interface not identified" : "interface not listed")
            }
            switch ipv4MappedGIDPresent {
            case true?: facts.append("IPv4-mapped GID published")
            case false?: facts.append("no IPv4-mapped GID")
            case nil: facts.append("GID table not read")
            }
        }
        return device + (interface.map { " (\($0))" } ?? "") + ": " + facts.joined(separator: " · ")
    }
}

extension ClusterLinkReadinessReport {
    /// What a ready result does and does not cover.
    static let readyScope = "Local interface state only: no peer was contacted and no collective ran."

    /// Compact operator text: the state, one line per device, then either the
    /// guidance or the scope of a ready result.
    public var summaryLines: [String] {
        ["Local link: \(state.rawValue)"] + devices.map { "  " + $0.summary } + [guidance ?? Self.readyScope]
    }
}
