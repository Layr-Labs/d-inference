import Foundation

/// One change seen by `darkbloom cluster link --watch`.
public struct ClusterLinkWatchEvent: Encodable, Sendable, Equatable {
    public enum Kind: String, Encodable, Sendable {
        /// The first poll: the state the watch starts from.
        case started
        case portUp
        case portDown
        case stateChanged
    }

    public let schema = "darkbloom_cluster_link_watch_v1"
    public let event: Kind
    /// The link state after this poll.
    public let state: ClusterLinkReadinessState
    public let previousState: ClusterLinkReadinessState?
    /// Port events name the device, its interface and its verdict.
    public let device: String?
    public let interface: String?
    public let verdict: ClusterLinkReadinessState?
    /// Whether `darkbloom cluster link --fix` applies to what this event reports.
    public let fixable: Bool
    /// Given with a state the fix applies to.
    public let guidance: String?

    /// Operator text: one line, and the guidance when there is any.
    public var lines: [String] {
        let port = ClusterLinkName.label(device: device ?? "", interface: interface)
        switch event {
        case .started:
            return ["Local link: \(state.rawValue)"] + [guidance].compactMap { $0 }
        case .stateChanged:
            return ["Local link: \(state.rawValue)" + (previousState.map { " (was \($0.rawValue))" } ?? "")]
                + [guidance].compactMap { $0 }
        case .portUp:
            return ["Port up: \(port)" + (verdict.map { " · \($0.rawValue)" } ?? "")]
        case .portDown:
            return ["Port down: \(port)"]
        }
    }
}

public enum ClusterLinkWatch {
    public static let pollIntervalSeconds = 2

    /// What changed between two polls: ports that came up or went down, in
    /// listing order, then the link state. `previous` is nil on the first poll.
    public static func events(previous: ClusterLinkReadinessReport?,
                              current: ClusterLinkReadinessReport) -> [ClusterLinkWatchEvent] {
        guard let previous else { return [stateEvent(.started, current.state, previous: nil)] }
        let wasActive = Set(previous.devices.filter(\.portActive).map(\.device))
        var events = current.devices.filter { $0.portActive != wasActive.contains($0.device) }.map { device in
            ClusterLinkWatchEvent(event: device.portActive ? .portUp : .portDown, state: current.state, previousState: nil,
                device: device.device, interface: device.interface, verdict: device.verdict,
                fixable: device.verdict.fixableByAddingAddress, guidance: nil)
        }
        // A device that left the listing was up and no longer is.
        let listed = Set(current.devices.map(\.device))
        events += previous.devices.filter { $0.portActive && !listed.contains($0.device) }.map { device in
            ClusterLinkWatchEvent(event: .portDown, state: current.state, previousState: nil, device: device.device,
                interface: device.interface, verdict: nil, fixable: false, guidance: nil)
        }
        if current.state != previous.state { events.append(stateEvent(.stateChanged, current.state, previous: previous.state)) }
        return events
    }

    private static func stateEvent(_ kind: ClusterLinkWatchEvent.Kind, _ state: ClusterLinkReadinessState,
                                   previous: ClusterLinkReadinessState?) -> ClusterLinkWatchEvent {
        ClusterLinkWatchEvent(event: kind, state: state, previousState: previous, device: nil, interface: nil, verdict: nil,
            fixable: state.fixableByAddingAddress, guidance: state.fixableByAddingAddress ? state.guidance : nil)
    }
}
