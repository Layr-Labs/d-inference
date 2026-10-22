import Foundation

/// One approval: the exact commands macOS is asked to run as an administrator
/// and the sentence its prompt shows. Every part is validated or generated
/// here; no operator-supplied text is ever placed in a command.
struct ClusterLinkPrivilegedRequest: Equatable, Sendable {
    enum Purpose: Equatable, Sendable {
        /// Give the port the address and install the job that keeps it there.
        case keepAddress
        /// Give the port the address until macOS next removes it.
        case addAddress
        /// Undo exactly these remnants of an earlier fix.
        case remove(ClusterLinkFixRemnants)
    }

    let purpose: Purpose
    let interface: String
    let address: ClusterLinkLocalAddress

    /// Nil unless `interface` is a plain interface name and there is something to do.
    init?(_ purpose: Purpose, interface: String, address: ClusterLinkLocalAddress) {
        guard ClusterLinkName.isInterface(interface) else { return nil }
        if case .remove(let remnants) = purpose, remnants.isEmpty { return nil }
        self.purpose = purpose
        self.interface = interface
        self.address = address
    }

    /// The exact commands, in order. Each is one line an administrator could
    /// also run by hand.
    var commands: [String] {
        let alias = "/sbin/ifconfig \(interface) inet \(address.dottedDecimal)"
        switch purpose {
        case .addAddress:
            return [alias + " netmask \(ClusterLinkLocalAddress.netmask) alias"]
        case .keepAddress:
            // `init` has validated the interface, so the keeper exists.
            return ClusterLinkAddressKeeper(interface: interface, address: address)?.installCommands ?? []
        case .remove(let remnants):
            // The job goes before the address it would put back. A loaded job
            // may have put the address back since the port was looked at, so
            // the address is taken away with it either way.
            return [
                remnants.keeperJob ? "/bin/launchctl bootout system/\(ClusterLinkAddressKeeper.label(forInterface: interface))" : nil,
                remnants.keeperFile ? "/bin/rm -f \(ClusterLinkAddressKeeper.plistPath(forInterface: interface))" : nil,
                remnants.address || remnants.keeperJob ? alias + " -alias" : nil,
            ].compactMap { $0 }
        }
    }

    /// One command line. A fix stops at the first command to fail. A removal
    /// runs every command, because each undoes one thing on its own; what is
    /// left afterwards decides how it ended, not the exit status.
    var shellCommand: String {
        if case .remove = purpose { return commands.joined(separator: "; ") }
        return commands.joined(separator: " && ")
    }

    /// What the macOS authorization prompt tells the person approving.
    var prompt: String {
        switch purpose {
        case .addAddress:
            return "Darkbloom wants to give Thunderbolt port \(interface) its own address so RDMA can use it."
        case .keepAddress:
            return "Darkbloom wants to give Thunderbolt port \(interface) its own address and keep it there so RDMA can use it."
        case .remove(let remnants):
            guard remnants.address || remnants.keeperJob else {
                return "Darkbloom wants to remove the job that kept an address on Thunderbolt port \(interface)."
            }
            let job = remnants.keeperJob || remnants.keeperFile ? " and the job that kept it there" : ""
            return "Darkbloom wants to remove the address it gave Thunderbolt port \(interface)\(job)."
        }
    }

    /// Nothing here needs AppleScript escaping: an interface name is ASCII
    /// letters and digits, the address is digits and dots, and the rest is
    /// fixed text without a double quote or a backslash.
    var appleScript: String {
        "do shell script \"\(shellCommand)\" with prompt \"\(prompt)\" with administrator privileges"
    }

    /// For an administrator to run by hand where no prompt can be shown.
    var manualCommands: [String] { commands.map { "sudo " + $0 } }
}
