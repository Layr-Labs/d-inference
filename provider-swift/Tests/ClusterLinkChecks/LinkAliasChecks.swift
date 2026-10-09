import Foundation

/// The address chosen for a port, the one privileged command built from it,
/// and how an approval attempt is read. Nothing here starts a process.
extension ClusterLinkCheck {
    static let hostileNames = ["", " ", "en6 ", " en6", "en6;id", "en6; rm -rf /", "en6\"", "en6'", "en6\\", "en6`id`",
        "$(id)", "en6\nen7", "en6\"; do shell script \"id", "-alias", "bridge0 inet 192.0.2.10", "en6/..", "en６",
        "0en6", "192.0.2.10", String(repeating: "e", count: 16)]

    static func linkLocalAddress() {
        func derived(_ machine: String, _ interface: String = "en6") -> String {
            ClusterLinkLocalAddress.derived(machineIdentifier: machine, interface: interface).dottedDecimal
        }
        // Known answers: SHA-256 of "darkbloom-cluster-link-v1\n<machine>\n<interface>".
        expectEqual(derived("00000000-0000-0000-0000-000000000001"), "169.254.64.135", "known answer")
        expectEqual(derived("00000000-0000-0000-0000-000000000002"), "169.254.4.177", "another machine differs")
        expectEqual(derived("00000000-0000-0000-0000-000000000001", "en7"), "169.254.159.111", "another port differs")
        expectEqual(derived(FakeRepairWorld.machine), FakeRepairWorld.en6Address, "fixture machine")
        expectEqual(derived("00000000-0000-0000-0000-000000000001"), derived("00000000-0000-0000-0000-000000000001"), "deterministic")

        let many = (0..<2000).map { ClusterLinkLocalAddress.derived(machineIdentifier: "machine-\($0)", interface: "en6") }
        expect(many.allSatisfy { (1...254).contains($0.third) && (1...254).contains($0.fourth) },
            "every derived address avoids the reserved /24s and .0/.255 hosts")
        expectEqual(Set(many.map(\.dottedDecimal)).count, 1972, "2000 machines spread over the link-local range")
        expect(many.allSatisfy { $0.dottedDecimal.range(of: #"^169\.254\.[0-9]{1,3}\.[0-9]{1,3}$"#, options: .regularExpression) != nil },
            "link-local dotted decimal")
        expectEqual(ClusterLinkLocalAddress.netmask, "255.255.0.0", "link-local netmask")

        expectEqual(ClusterLinkLocalAddress(dottedDecimal: "169.254.10.20")?.dottedDecimal, "169.254.10.20", "record round trip")
        expectEqual(ClusterLinkLocalAddress(dottedDecimal: "169.254.1.1").map { [$0.third, $0.fourth] }, [1, 1], "lowest address")
        expectEqual(ClusterLinkLocalAddress(dottedDecimal: "169.254.254.254").map { [$0.third, $0.fourth] }, [254, 254], "highest address")
        for invalid in ["", "169.254.0.5", "169.254.255.5", "169.254.5.0", "169.254.5.255", "169.254.5", "169.254.5.6.7",
                        "10.0.0.1", "192.0.2.10", "169.254.05.6", "169.254.5.+6", "169.254.5.6 ", " 169.254.5.6", "169.254.5.6\n",
                        "169.254.5.6; id", "169.254.256.1", "169.254.-1.1", "169.254.5.６", "169.254.0x5.6", "::ffff:169.254.5.6"] {
            expect(ClusterLinkLocalAddress(dottedDecimal: invalid) == nil, "address \(invalid.debugDescription) is refused")
        }
        expect(ClusterLinkLocalAddress(third: 0, fourth: 9) == nil && ClusterLinkLocalAddress(third: 255, fourth: 9) == nil
            && ClusterLinkLocalAddress(third: 9, fourth: 0) == nil && ClusterLinkLocalAddress(third: 9, fourth: 255) == nil,
            "out-of-range octets are refused")
    }

    static func aliasCommand() {
        guard let address = ClusterLinkLocalAddress(dottedDecimal: "169.254.10.20") else { expect(false, "fixture address"); return }
        let add = ClusterLinkAliasCommand(action: .add, interface: "en6", address: address)
        expectEqual(add?.shellCommand, "/sbin/ifconfig en6 inet 169.254.10.20 netmask 255.255.0.0 alias", "add command")
        expectEqual(add?.prompt, "Darkbloom wants to give Thunderbolt port en6 its own address so RDMA can use it.", "add prompt")
        expectEqual(add?.appleScript, "do shell script \"/sbin/ifconfig en6 inet 169.254.10.20 netmask 255.255.0.0 alias\" "
            + "with prompt \"Darkbloom wants to give Thunderbolt port en6 its own address so RDMA can use it.\" "
            + "with administrator privileges", "add script")
        expectEqual(add?.manualCommand, "sudo /sbin/ifconfig en6 inet 169.254.10.20 netmask 255.255.0.0 alias", "manual add command")

        let remove = ClusterLinkAliasCommand(action: .remove, interface: "en6", address: address)
        expectEqual(remove?.shellCommand, "/sbin/ifconfig en6 inet 169.254.10.20 -alias", "remove command")
        expectEqual(remove?.prompt, "Darkbloom wants to remove the address it gave Thunderbolt port en6.", "remove prompt")
        expectEqual(remove?.appleScript, "do shell script \"/sbin/ifconfig en6 inet 169.254.10.20 -alias\" "
            + "with prompt \"Darkbloom wants to remove the address it gave Thunderbolt port en6.\" with administrator privileges",
            "remove script")
        expectEqual(remove?.manualCommand, "sudo /sbin/ifconfig en6 inet 169.254.10.20 -alias", "manual remove command")

        expectEqual(ClusterLinkApproval.executable, "/usr/bin/osascript", "approval tool")
        expectEqual(add.map(ClusterLinkApproval.arguments(for:)), add.map { ["-e", $0.appleScript] }, "one script argument, no shell")

        // No hostile text can become part of the privileged command: the type
        // refuses to exist for it, for either action.
        for name in hostileNames {
            expect(ClusterLinkAliasCommand(action: .add, interface: name, address: address) == nil,
                "no add command for interface \(name.debugDescription)")
            expect(ClusterLinkAliasCommand(action: .remove, interface: name, address: address) == nil,
                "no remove command for interface \(name.debugDescription)")
            expect(ClusterLinkName.interface(ofDevice: "rdma_" + name) == nil, "no interface for device rdma_\(name.debugDescription)")
        }

        // Whatever valid parts it is built from, the script has one fixed shape.
        let shape = #"^do shell script "/sbin/ifconfig [A-Za-z][A-Za-z0-9]{0,14} inet 169\.254\.[0-9]{1,3}\.[0-9]{1,3}( netmask 255\.255\.0\.0 alias| -alias)" with prompt "[A-Za-z0-9 ]+\." with administrator privileges$"#
        for interface in ["en6", "en12", "bridge0", "E", String(repeating: "e", count: 15)] {
            for third in [UInt8(1), 127, 254] {
                for action in [ClusterLinkAliasCommand.Action.add, .remove] {
                    guard let address = ClusterLinkLocalAddress(third: third, fourth: 254 - third + 1),
                          let command = ClusterLinkAliasCommand(action: action, interface: interface, address: address) else {
                        expect(false, "valid command for \(interface)"); continue
                    }
                    let script = command.appleScript
                    expect(script.range(of: shape, options: .regularExpression) != nil, "script shape for \(interface)")
                    expect(script.filter { $0 == "\"" }.count == 4 && !script.contains("\\") && !script.contains("\n"),
                        "script quoting for \(interface)")
                }
            }
        }
    }

    static func approvalResults() {
        func result(_ status: Int32, _ output: String) -> ClusterLinkApprovalResult {
            ClusterLinkApproval.result(of: .exited(status: status, output: output))
        }
        expectEqual(result(0, ""), .applied, "exit 0 means the command ran")
        expectEqual(result(0, "anything (-128)\n"), .applied, "exit status decides before any text")
        expectEqual(result(1, "0:17: execution error: User canceled. (-128)\n"), .declined, "prompt cancelled")
        expectEqual(result(1, "0:90: execution error: The operation was cancelled. (-60006)\n"), .declined, "authorization cancelled")
        expectEqual(result(1, "0:90: execution error: No user interaction is possible. (-60007)\n"), .unavailable, "no interaction allowed")
        expectEqual(result(1, "0:90: execution error: The administrator user name or password was incorrect. (-60005)\n"), .unavailable,
            "authorization denied")
        expectEqual(result(1, "0:90: execution error: Not authorized to send Apple events. (-1743)\n"), .unavailable, "another negative error")
        expectEqual(result(1, "0:90: execution error: The command exited with a non-zero status. (1)\n"), .commandFailed, "ifconfig failed")
        expectEqual(result(1, "0:90: execution error: ifconfig: ioctl (SIOCAIFADDR): File exists (1)\n"), .commandFailed,
            "ifconfig failed with its own parenthesised text")
        expectEqual(result(1, ""), .unavailable, "no explanation")
        expectEqual(result(1, "unexpected text\n"), .unavailable, "unrecognized text")
        expectEqual(result(1, "(-128) and then more text\n"), .unavailable, "an error number that is not at the end")
        expectEqual(result(1, "execution error: (0)\n"), .unavailable, "zero is not a command failure")
        expectEqual(result(127, "sh: command not found (127)\n"), .unavailable, "osascript itself did not report a script error")
        for execution in [ClusterLinkToolProcess.Execution.abnormal, .timedOut, .outputTooLarge] {
            expectEqual(ClusterLinkApproval.result(of: execution), .unavailable, "\(execution) is unavailability")
        }
    }
}
