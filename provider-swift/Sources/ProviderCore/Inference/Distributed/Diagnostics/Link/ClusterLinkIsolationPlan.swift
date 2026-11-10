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
    /// Darkbloom's service exists already: it is reconfigured in place, never removed and made again (macOS refuses
    /// to remove a port's only service, which Darkbloom's is on a Mac whose ports start in the Thunderbolt Bridge).
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
            // Switched on again, in case an earlier removal switched it off; then set as below.
            commands.append("/usr/sbin/networksetup -setnetworkserviceenabled \(quotedService) on")
        } else {
            commands.append("/usr/sbin/networksetup -createnetworkservice \(quotedService) '\(hardwarePort)'")
        }
        commands += [
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
    /// Darkbloom's service is the port's only one, which `networksetup -removenetworkservice` refuses ("there aren't
    /// any other network services on Thunderbolt 2", pair-2's MacBook): it is removed through SCPreferences instead.
    let lastService: ClusterLinkLastService?

    init?(interface: String, removeClusterService: Bool, servicesToEnable: [String],
          bridge: ClusterLinkIsolationPlan.BridgeSlot?, addressToRemove: ClusterLinkClusterAddress?, keeperToRemove: Bool,
          lastService: ClusterLinkLastService? = nil) {
        guard ClusterLinkName.isInterface(interface), servicesToEnable.allSatisfy(ClusterLinkServiceName.isSafe),
              bridge.map({ ClusterLinkName.isInterface($0.bridge) && $0.index >= 0 }) ?? true else { return nil }
        self.interface = interface
        self.removeClusterService = removeClusterService
        self.servicesToEnable = servicesToEnable
        self.bridge = bridge
        self.addressToRemove = addressToRemove
        self.keeperToRemove = keeperToRemove
        self.lastService = removeClusterService ? lastService : nil
    }

    var isEmpty: Bool {
        !removeClusterService && servicesToEnable.isEmpty && bridge == nil && addressToRemove == nil && !keeperToRemove
    }

    /// In order, and the shell stops at the first that fails
    /// (`ClusterLinkIsolationRequest.shellCommand`); what is left afterwards
    /// decides how the removal ended. Darkbloom's service goes first, then
    /// its address, and only then does the port go back into its bridge: a
    /// bridge entry written while the service still held the port left it in
    /// both (pair-2's MacBook, R5-2: "not isolated: member of bridge0"). The
    /// services switched on after the entry make macOS apply it.
    var commands: [String] { commands(leavingOrder: lastService.map { [$0.serviceID] } ?? []) }

    /// The commands, with `leavingOrder` the service IDs every removal of the same approval takes out of the service
    /// order (each port's commands set the whole order, so each must leave out all of them).
    func commands(leavingOrder: [String]) -> [String] {
        var commands = [String]()
        if keeperToRemove {
            // A keeper whose file is there but whose job is not loaded has nothing to boot out; what is left is read afterwards.
            commands.append("/bin/launchctl bootout system/\(ClusterLinkAddressKeeper.label(forInterface: interface)) 2>/dev/null || true")
            commands.append("/bin/rm -f \(ClusterLinkAddressKeeper.plistPath(forInterface: interface))")
        }
        if let lastService {
            commands += lastService.removal(service: ClusterLinkServiceName.cluster(interface: interface), interface: interface,
                                            leavingOrder: leavingOrder)
        } else if removeClusterService {
            commands.append("/usr/sbin/networksetup -removenetworkservice '\(ClusterLinkServiceName.cluster(interface: interface))'")
        }
        if let addressToRemove {
            commands.append("/sbin/ifconfig \(interface) inet \(addressToRemove.dottedDecimal) -alias")
        }
        if let bridge {
            let entry = ":VirtualNetworkInterfaces:Bridge:\(bridge.bridge):Interfaces:\(bridge.index)"
            commands.append("/usr/libexec/PlistBuddy -c 'Add \(entry) string \(interface)' \(ClusterLinkIsolationPlan.networkPreferences)")
        }
        commands += servicesToEnable.map { "/usr/sbin/networksetup -setnetworkserviceenabled '\($0)' on" }
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
        /// Every port in one approval (R5-2: an uninstall undoes all the ports Darkbloom set up, never one of them).
        case restore([ClusterLinkIsolationRestore])
    }

    let purpose: Purpose

    /// Nil for a restore with nothing to do.
    init?(_ purpose: Purpose) {
        if case .restore(let restores) = purpose {
            let pending = restores.filter { !$0.isEmpty }
            guard !pending.isEmpty else { return nil }
            self.purpose = .restore(pending)
            return
        }
        self.purpose = purpose
    }

    /// The single port: the isolation's, or the first restored.
    var interface: String {
        switch purpose {
        case .isolate(let plan): return plan.interface
        case .restore(let restores): return restores[0].interface
        }
    }

    /// Every port the approval changes.
    var interfaces: [String] {
        switch purpose {
        case .isolate(let plan): return [plan.interface]
        case .restore(let restores): return restores.map(\.interface)
        }
    }

    var commands: [String] {
        switch purpose {
        case .isolate(let plan): return plan.commands
        case .restore(let restores):
            let removed = restores.compactMap { $0.lastService?.serviceID }
            return restores.flatMap { $0.commands(leavingOrder: removed) }
        }
    }

    /// One shell line that stops at the first failing command, for an
    /// isolation and a restore alike: a failure is then exactly where it
    /// says, and nothing after it ran.
    var shellCommand: String { "set -e; " + commands.joined(separator: "; ") }

    var prompt: String {
        switch purpose {
        case .isolate(let plan):
            var actions = ["give Thunderbolt port \(plan.interface) its own network service with a fixed address and no router or DNS"]
            if !plan.servicesToDisable.isEmpty { actions.append("switch the other service on that port off") }
            if let bridge = plan.bridge { actions.append("take the port out of \(bridge.bridge)") }
            let sentence = actions.count == 1 ? actions[0] : actions.dropLast().joined(separator: ", ") + " and " + actions[actions.count - 1]
            return "Darkbloom wants to \(sentence), so RDMA can use it."
        case .restore(let restores):
            guard restores.count > 1 else {
                return "Darkbloom wants to restore the network settings of Thunderbolt port \(restores[0].interface) to how they were before it set the port up."
            }
            return "Darkbloom wants to restore the network settings of Thunderbolt ports \(ClusterLinkIsolationRequest.list(restores.map(\.interface))) to how they were before it set them up."
        }
    }

    /// Interface and bridge names are letters and digits, addresses digits and dots, service IDs hexadecimal and
    /// hyphens, service and hardware port names pass `ClusterLinkServiceName.isSafe`; the fixed text has no double
    /// quote. A removal through SCPreferences carries the shell's double quotes and `\n`, escaped for AppleScript.
    var appleScript: String {
        let escaped = shellCommand.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return "do shell script \"\(escaped)\" with prompt \"\(prompt)\" with administrator privileges"
    }

    /// For an administrator to paste where no prompt can be shown and no script could be written: the same commands,
    /// one per line, in one root shell under `set -e` (a line each behind `sudo` would break on `if …; fi` and give
    /// root to `printf` alone in `printf … | scutil`). No generated line can be the delimiter: each starts with a path
    /// or a shell keyword.
    var manualCommands: [String] {
        ["sudo /bin/sh -e <<'\(Self.manualDelimiter)'"] + commands + [Self.manualDelimiter]
    }

    static let manualDelimiter = "DARKBLOOM_CLUSTER_LINK"

    /// "en6", "en6 and en1", "en6, en1 and en2".
    static func list(_ names: [String]) -> String {
        names.count < 2 ? names.joined() : names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
    }
}

/// Darkbloom's service when it is its port's only one, as macOS keeps it in its preferences: its ID, the current
/// network set and that set's IPv4 service order, read before the approval (the file is world-readable). The removal
/// is checked again as an administrator: the ID must still name Darkbloom's service on that port.
struct ClusterLinkLastService: Equatable, Sendable {
    let serviceID: String
    let set: String
    /// Nil when the set keeps no IPv4 service order.
    let serviceOrder: [String]?

    init?(serviceID: String, set: String, serviceOrder: [String]?) {
        guard Self.isID(serviceID), Self.isID(set), serviceOrder?.allSatisfy(Self.isID) ?? true else { return nil }
        self.serviceID = serviceID; self.set = set; self.serviceOrder = serviceOrder
    }

    /// A service or set ID as macOS writes them: 36 characters of ASCII hexadecimal digits and hyphens (never a
    /// fullwidth digit, which `Character.isHexDigit` accepts).
    static func isID(_ text: String) -> Bool {
        let scalars = text.unicodeScalars
        return scalars.count == 36 && scalars.filter { $0 == "-" }.count == 4 && scalars.allSatisfy {
            $0 == "-" || ("0"..."9").contains($0) || ("A"..."F").contains($0) || ("a"..."f").contains($0)
        }
    }

    /// The ID of `service` on `interface` in `NetworkServices` (`plutil -extract NetworkServices json`): exactly one.
    static func serviceID(of service: String, on interface: String, inPreferences json: String) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else { return nil }
        let matches = object.compactMap { id, value -> String? in
            guard let entry = value as? [String: Any], entry["UserDefinedName"] as? String == service,
                  (entry["Interface"] as? [String: Any])?["DeviceName"] as? String == interface else { return nil }
            return id
        }
        return matches.count == 1 ? matches[0] : nil
    }

    /// The commands: the name and the device checked as an administrator, then one SCPreferences session (`scutil
    /// --prefs`) that removes the service and its link in the set, sets the order without `leavingOrder`, commits and
    /// applies; then a read-back that the service is gone, which stops the script when it is not. Proven on pair-2's
    /// MacBook (macOS 27.0, 2026-11-04): the port's last service went, and macOS put the port back in its saved
    /// bridge by itself.
    func removal(service: String, interface: String, leavingOrder: [String]) -> [String] {
        let preferences = ClusterLinkIsolationPlan.networkPreferences
        let entry = ":NetworkServices:\(serviceID)"
        var session = ["remove /NetworkServices/\(serviceID)", "remove /Sets/\(set)/Network/Service/\(serviceID)"]
        if let serviceOrder {
            let order = serviceOrder.filter { !leavingOrder.contains($0) && $0 != serviceID }
            session += ["get /Sets/\(set)/Network/Global/IPv4",
                        order.isEmpty ? "d.remove ServiceOrder" : "d.add ServiceOrder * " + order.joined(separator: " "),
                        "set /Sets/\(set)/Network/Global/IPv4"]
        }
        session += ["commit", "apply"]
        return [
            "/usr/libexec/PlistBuddy -c 'Print \(entry):UserDefinedName' \(preferences) | /usr/bin/grep -qxF '\(service)'",
            "/usr/libexec/PlistBuddy -c 'Print \(entry):Interface:DeviceName' \(preferences) | /usr/bin/grep -qxF \(interface)",
            "/usr/bin/printf '%s\\n' " + session.map { "'\($0)'" }.joined(separator: " ") + " | /usr/sbin/scutil --prefs",
            // `scutil` exits 0 even when its `commit` fails, and a `!` command does not stop `set -e`: a service still
            // there ends the script, so the port never goes back into its bridge beside it.
            "if /usr/libexec/PlistBuddy -c 'Print \(entry)' \(preferences) >/dev/null 2>&1; then exit 1; fi",
        ]
    }
}
