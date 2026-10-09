import Foundation

/// The one privileged change the link fix makes, and its reversal: an IPv4
/// alias on one Thunderbolt port. Every part is validated or generated here;
/// no operator-supplied text is ever placed in the command.
struct ClusterLinkAliasCommand: Equatable, Sendable {
    enum Action: Equatable, Sendable { case add, remove }

    let action: Action
    let interface: String
    let address: ClusterLinkLocalAddress

    /// Nil unless `interface` is a plain interface name.
    init?(action: Action, interface: String, address: ClusterLinkLocalAddress) {
        guard ClusterLinkName.isInterface(interface) else { return nil }
        self.action = action
        self.interface = interface
        self.address = address
    }

    var shellCommand: String {
        switch action {
        case .add:
            return "/sbin/ifconfig \(interface) inet \(address.dottedDecimal) netmask \(ClusterLinkLocalAddress.netmask) alias"
        case .remove:
            return "/sbin/ifconfig \(interface) inet \(address.dottedDecimal) -alias"
        }
    }

    /// What the macOS authorization prompt tells the person approving.
    var prompt: String {
        switch action {
        case .add: return "Darkbloom wants to give Thunderbolt port \(interface) its own address so RDMA can use it."
        case .remove: return "Darkbloom wants to remove the address it gave Thunderbolt port \(interface)."
        }
    }

    /// Nothing here needs AppleScript escaping: an interface name is ASCII
    /// letters and digits, the address is digits and dots, the rest is fixed.
    var appleScript: String {
        "do shell script \"\(shellCommand)\" with prompt \"\(prompt)\" with administrator privileges"
    }

    /// For an administrator to run by hand where no prompt can be shown.
    var manualCommand: String { "sudo " + shellCommand }
}
