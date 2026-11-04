import Foundation

/// What the one approval of link setup v2 changes for a cluster port, as the
/// exact ordered commands macOS runs as an administrator.
///
/// The end state follows the pattern of the owner's earlier cluster tools
/// (exo, ThunderMLX, oMLX): the port is outside every bridge and has a network
/// service of its own with a fixed IPv4 address, no router and no DNS. macOS
/// itself then keeps that address, after a restart too, and nothing but the
/// cluster uses the cable. Unlike exo, no network location is switched, the
/// Thunderbolt Bridge is not destroyed, the other members stay in it, and
/// Internet Sharing is not touched.
struct ClusterLinkIsolationPlan: Equatable, Sendable {
    static let networkPreferences = "/Library/Preferences/SystemConfiguration/preferences.plist"
    static let internetSharingPreferences = "/Library/Preferences/SystemConfiguration/com.apple.nat.plist"

    /// Where the port sits in a bridge of the network settings.
    struct BridgeSlot: Equatable, Sendable {
        let bridge: String
        let index: Int
    }

    let interface: String
    let address: ClusterLinkClusterAddress
    /// The hardware port the new service is made on, such as "Thunderbolt 2".
    let hardwarePort: String
    /// The bridge the port leaves, when it is in one.
    let bridge: BridgeSlot?
    /// Enabled services on the port that are switched off, by name.
    let servicesToDisable: [String]
    /// Darkbloom's service exists already and is made afresh.
    let replaceClusterService: Bool
    /// The first version's link-local address, taken off the port.
    let linkLocalToRemove: ClusterLinkLocalAddress?
    /// The first version's address keeper is installed and goes: macOS keeps
    /// the new address itself.
    let keeperToRemove: Bool

    /// Nil unless every name is one Darkbloom will place in a command.
    init?(interface: String, address: ClusterLinkClusterAddress, hardwarePort: String, bridge: BridgeSlot?,
          servicesToDisable: [String], replaceClusterService: Bool, linkLocalToRemove: ClusterLinkLocalAddress?,
          keeperToRemove: Bool) {
        guard ClusterLinkName.isInterface(interface), ClusterLinkServiceName.isSafe(hardwarePort),
              servicesToDisable.allSatisfy(ClusterLinkServiceName.isSafe),
              !servicesToDisable.contains(ClusterLinkServiceName.cluster(interface: interface)),
              bridge.map({ ClusterLinkName.isInterface($0.bridge) && $0.index >= 0 }) ?? true else { return nil }
        self.interface = interface
        self.address = address
        self.hardwarePort = hardwarePort
        self.bridge = bridge
        self.servicesToDisable = servicesToDisable
        self.replaceClusterService = replaceClusterService
        self.linkLocalToRemove = linkLocalToRemove
        self.keeperToRemove = keeperToRemove
    }

    var service: String { ClusterLinkServiceName.cluster(interface: interface) }

    /// In order. They run under `set -e`: the first command to fail stops the
    /// rest, except the few marked `|| true` that only tidy what may be gone.
    var commands: [String] {
        let quotedService = "'\(service)'"
        var commands = [String]()
        if keeperToRemove {
            // The old job goes first, so it cannot put the old address back.
            commands.append("/bin/launchctl bootout system/\(ClusterLinkAddressKeeper.label(forInterface: interface)) 2>/dev/null || true")
            commands.append("/bin/rm -f \(ClusterLinkAddressKeeper.plistPath(forInterface: interface))")
        }
        if let linkLocalToRemove {
            commands.append("/sbin/ifconfig \(interface) inet \(linkLocalToRemove.dottedDecimal) -alias 2>/dev/null || true")
        }
        if let bridge {
            // The member is checked by position first, so a list that changed
            // since it was read stops the change instead of losing another port.
            let entry = ":VirtualNetworkInterfaces:Bridge:\(bridge.bridge):Interfaces:\(bridge.index)"
            commands.append("/usr/libexec/PlistBuddy -c 'Print \(entry)' \(Self.networkPreferences) | /usr/bin/grep -qx \(interface)")
            commands.append("/usr/libexec/PlistBuddy -c 'Delete \(entry)' \(Self.networkPreferences)")
            // The settings take effect with the next service change below; the
            // running bridge lets go of the port now.
            commands.append("/sbin/ifconfig \(bridge.bridge) deletem \(interface) 2>/dev/null || true")
        }
        if replaceClusterService {
            commands.append("/usr/sbin/networksetup -removenetworkservice \(quotedService)")
        }
        commands += [
            "/usr/sbin/networksetup -createnetworkservice \(quotedService) '\(hardwarePort)'",
            // No router: no default route through the cable.
            "/usr/sbin/networksetup -setmanual \(quotedService) \(address.dottedDecimal) \(ClusterLinkClusterAddress.netmask)",
            "/usr/sbin/networksetup -setdnsservers \(quotedService) Empty",
            // No router advertisements, so no IPv6 route or DNS through the cable either.
            "/usr/sbin/networksetup -setv6LinkLocal \(quotedService)",
        ]
        commands += servicesToDisable.map { "/usr/sbin/networksetup -setnetworkserviceenabled '\($0)' off" }
        return commands
    }
}

/// What `darkbloom cluster link --remove` undoes for a port that link setup
/// v2 isolated: everything it changed, back to how it was before.
struct ClusterLinkIsolationRestore: Equatable, Sendable {
    let interface: String
    /// Darkbloom's service is still there.
    let removeClusterService: Bool
    /// Services the approval switched off that are off still.
    let servicesToEnable: [String]
    /// The bridge the port goes back into, at its old position, when the
    /// approval took it out and it is not back.
    let bridge: ClusterLinkIsolationPlan.BridgeSlot?
    /// The cluster address, when the port still carries it after its service is gone.
    let addressToRemove: ClusterLinkClusterAddress?
    /// A first-version keeper is still installed.
    let keeperToRemove: Bool

    init?(interface: String, removeClusterService: Bool, servicesToEnable: [String],
          bridge: ClusterLinkIsolationPlan.BridgeSlot?, addressToRemove: ClusterLinkClusterAddress?, keeperToRemove: Bool) {
        guard ClusterLinkName.isInterface(interface), servicesToEnable.allSatisfy(ClusterLinkServiceName.isSafe),
              bridge.map({ ClusterLinkName.isInterface($0.bridge) && $0.index >= 0 }) ?? true else { return nil }
        self.interface = interface
        self.removeClusterService = removeClusterService
        self.servicesToEnable = servicesToEnable
        self.bridge = bridge
        self.addressToRemove = addressToRemove
        self.keeperToRemove = keeperToRemove
    }

    var isEmpty: Bool {
        !removeClusterService && servicesToEnable.isEmpty && bridge == nil && addressToRemove == nil && !keeperToRemove
    }

    /// In order. Every command runs, because each undoes one thing on its
    /// own; what is left afterwards decides how the removal ended.
    var commands: [String] {
        var commands = [String]()
        if keeperToRemove {
            commands.append("/bin/launchctl bootout system/\(ClusterLinkAddressKeeper.label(forInterface: interface))")
            commands.append("/bin/rm -f \(ClusterLinkAddressKeeper.plistPath(forInterface: interface))")
        }
        if let bridge {
            // Written before the service changes below, which make the
            // settings take effect.
            let entry = ":VirtualNetworkInterfaces:Bridge:\(bridge.bridge):Interfaces:\(bridge.index)"
            commands.append("/usr/libexec/PlistBuddy -c 'Add \(entry) string \(interface)' \(ClusterLinkIsolationPlan.networkPreferences)")
        }
        if removeClusterService {
            commands.append("/usr/sbin/networksetup -removenetworkservice '\(ClusterLinkServiceName.cluster(interface: interface))'")
        }
        commands += servicesToEnable.map { "/usr/sbin/networksetup -setnetworkserviceenabled '\($0)' on" }
        if let addressToRemove {
            commands.append("/sbin/ifconfig \(interface) inet \(addressToRemove.dottedDecimal) -alias")
        }
        if let bridge {
            commands.append("/sbin/ifconfig \(bridge.bridge) addm \(interface)")
        }
        return commands
    }
}

/// One approval of link setup v2: the exact commands and the sentence the
/// macOS prompt shows. Every part is validated or generated; nothing an
/// operator typed reaches it.
struct ClusterLinkIsolationRequest: Equatable, Sendable {
    enum Purpose: Equatable, Sendable {
        case isolate(ClusterLinkIsolationPlan)
        case restore(ClusterLinkIsolationRestore)
    }

    let purpose: Purpose

    /// Nil for a restore with nothing to do.
    init?(_ purpose: Purpose) {
        if case .restore(let restore) = purpose, restore.isEmpty { return nil }
        self.purpose = purpose
    }

    var interface: String {
        switch purpose {
        case .isolate(let plan): return plan.interface
        case .restore(let restore): return restore.interface
        }
    }

    var commands: [String] {
        switch purpose {
        case .isolate(let plan): return plan.commands
        case .restore(let restore): return restore.commands
        }
    }

    /// One shell line: the isolation stops at the first failing command, the
    /// restore runs every command.
    var shellCommand: String {
        switch purpose {
        case .isolate: return "set -e; " + commands.joined(separator: "; ")
        case .restore: return commands.joined(separator: "; ")
        }
    }

    var prompt: String {
        switch purpose {
        case .isolate(let plan):
            var actions = ["give Thunderbolt port \(plan.interface) its own network service with a fixed address and no router or DNS"]
            if !plan.servicesToDisable.isEmpty { actions.append("switch the other service on that port off") }
            if let bridge = plan.bridge { actions.append("take the port out of \(bridge.bridge)") }
            let sentence = actions.count == 1 ? actions[0] : actions.dropLast().joined(separator: ", ") + " and " + actions[actions.count - 1]
            return "Darkbloom wants to \(sentence), so RDMA can use it."
        case .restore(let restore):
            return "Darkbloom wants to restore the network settings of Thunderbolt port \(restore.interface) to how they were before it set the port up."
        }
    }

    /// Nothing here needs AppleScript escaping: interface and bridge names are
    /// letters and digits, addresses digits and dots, service and hardware
    /// port names pass `ClusterLinkServiceName.isSafe`, and the fixed text has
    /// no double quote and no backslash.
    var appleScript: String {
        "do shell script \"\(shellCommand)\" with prompt \"\(prompt)\" with administrator privileges"
    }

    /// For an administrator to run by hand where no prompt can be shown.
    var manualCommands: [String] { commands.map { "sudo " + $0 } }
}
