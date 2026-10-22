import Foundation

/// The address chosen for a port, the launchd job that keeps it there, the
/// privileged requests built from both, and how an approval attempt is read.
/// Nothing here starts a process.
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

    static func addressKeeper() {
        guard let address = ClusterLinkLocalAddress(dottedDecimal: "169.254.10.20"),
              let keeper = ClusterLinkAddressKeeper(interface: "en6", address: address) else { expect(false, "fixture keeper"); return }
        expectEqual(keeper.label, "io.darkbloom.cluster-link.en6", "job label")
        expectEqual(keeper.plistPath, "/Library/LaunchDaemons/io.darkbloom.cluster-link.en6.plist", "job definition path")
        expectEqual(ClusterLinkAddressKeeper.intervalSeconds, 10, "check interval")
        // The job adds the address only when the port has no IPv4 address at
        // all, and is written without a quote so that it nests in one argument.
        let script = "/sbin/ifconfig en6 | /usr/bin/grep -qw inet || /sbin/ifconfig en6 inet 169.254.10.20 netmask 255.255.0.0 alias"
        expectEqual(keeper.script, script, "job script")
        expectEqual(keeper.programArguments, ["/bin/sh", "-c", script], "job program")
        let path = "/Library/LaunchDaemons/io.darkbloom.cluster-link.en6.plist"
        expectEqual(keeper.installCommands, [
            "/bin/launchctl bootout system/io.darkbloom.cluster-link.en6 2>/dev/null || true",
            "/bin/rm -f \(path)",
            "/usr/bin/plutil -create xml1 \(path)",
            "/usr/bin/plutil -insert Label -string io.darkbloom.cluster-link.en6 \(path)",
            "/usr/bin/plutil -insert ProgramArguments -array \(path)",
            "/usr/bin/plutil -insert ProgramArguments.0 -string /bin/sh \(path)",
            "/usr/bin/plutil -insert ProgramArguments.1 -string -c \(path)",
            "/usr/bin/plutil -insert ProgramArguments.2 -string '\(script)' \(path)",
            "/usr/bin/plutil -insert RunAtLoad -bool true \(path)",
            "/usr/bin/plutil -insert StartInterval -integer 10 \(path)",
            "/usr/sbin/chown root:wheel \(path)",
            "/bin/chmod 644 \(path)",
            "/bin/sh -c '\(script)'",
            "/bin/launchctl bootstrap system \(path)",
        ], "install commands, in order")
        // A removal could not take an entry out of launchd's database of enabled and disabled jobs again.
        expect(!keeper.installCommands.contains { $0.contains("launchctl enable") || $0.contains("launchctl disable") },
            "the install writes nothing that a removal cannot undo")

        // Recognised from what `plutil -convert json` prints, whatever the key order.
        expect(keeper.isDescribed(byJobJSON: LinkFixtures.keeperJobJSON(interface: "en6", address: "169.254.10.20")), "its own job definition")
        let reordered = "{\"RunAtLoad\":true,\"Label\":\"io.darkbloom.cluster-link.en6\",\"StartInterval\":10,"
            + "\"ProgramArguments\":[\"/bin/sh\",\"-c\",\"\(script)\"]}"
        expect(keeper.isDescribed(byJobJSON: reordered), "its job definition in another key order")
        for (label, other) in [
            ("another address", LinkFixtures.keeperJobJSON(interface: "en6", address: "169.254.10.21")),
            ("another port", LinkFixtures.keeperJobJSON(interface: "en5", address: "169.254.10.20")),
            ("another interval", LinkFixtures.keeperJobJSON(interface: "en6", address: "169.254.10.20", interval: 60)),
            ("an extra key", reordered.replacingOccurrences(of: "{\"RunAtLoad\"", with: "{\"UserName\":\"nobody\",\"RunAtLoad\"")),
            ("another program", reordered.replacingOccurrences(of: "/bin/sh", with: "/bin/zsh")),
            ("a missing key", reordered.replacingOccurrences(of: "\"RunAtLoad\":true,", with: "")),
            ("a number for true", reordered.replacingOccurrences(of: "\"RunAtLoad\":true", with: "\"RunAtLoad\":1")),
            ("a fractional interval", reordered.replacingOccurrences(of: "\"StartInterval\":10", with: "\"StartInterval\":10.0")),
            ("a truth value for the interval", reordered.replacingOccurrences(of: "\"StartInterval\":10", with: "\"StartInterval\":true")),
            ("not JSON", "unexpected text\n"), ("empty", ""), ("an array", "[]"),
        ] {
            expect(!keeper.isDescribed(byJobJSON: other), "a job definition with \(label) is not its own")
        }
        for name in hostileNames {
            expect(ClusterLinkAddressKeeper(interface: name, address: address) == nil, "no keeper for interface \(name.debugDescription)")
        }

        // Running means loaded in launchd and written exactly as installed.
        var installed = FakeLinkTools.macB
        expectEqual(keeper.isRunning(run: installed.outcome(of:)), false, "no keeper on an untouched Mac")
        installed.installKeeper(interface: "en6", address: "169.254.10.20")
        expectEqual(keeper.isRunning(run: installed.outcome(of:)), true, "an installed and loaded keeper")
        var unloaded = installed, rewritten = installed, unreadJob = installed, unreadFile = installed
        unloaded.keeperJobs = [:]
        rewritten.keeperJobFiles["en6"] = .output(LinkFixtures.keeperJobJSON(interface: "en6", address: "169.254.10.21"))
        unreadJob.keeperJobs["en6"] = .timedOut
        unreadFile.keeperJobFiles["en6"] = .outputTooLarge
        expectEqual(keeper.isRunning(run: unloaded.outcome(of:)), false, "a job definition that is not loaded is not running")
        expectEqual(keeper.isRunning(run: rewritten.outcome(of:)), false, "a job for another address is not this keeper")
        expectEqual([keeper.isRunning(run: unreadJob.outcome(of:)), keeper.isRunning(run: unreadFile.outcome(of:))], [nil, nil],
            "a reading that could not finish says neither")

        // Which ports have a job definition, from the directory's names alone.
        let listing = "com.example.agent.plist\nio.darkbloom.cluster-link.en6.plist\nio.darkbloom.cluster-link.en12.plist\n"
            + "io.darkbloom.cluster-link..plist\nio.darkbloom.cluster-link.en6.plist.bak\nio.darkbloom.cluster-link.en 6.plist\n"
            + "io.darkbloom.cluster-link.en6;x.plist\nxio.darkbloom.cluster-link.en7.plist\nio.darkbloom.other.plist\n"
        expectEqual(ClusterLinkAddressKeeper.installedInterfaces(inListing: listing), ["en6", "en12"], "only exact keeper file names count")
        expectEqual(ClusterLinkAddressKeeper.installedInterfaces(inListing: ""), [], "an empty directory has none")

        // A keeper is recognised as Darkbloom's own from its job definition alone, address included.
        let own = LinkFixtures.keeperJobJSON(interface: "en6", address: "169.254.10.20")
        expectEqual(ClusterLinkAddressKeeper.described(byJobJSON: own, interface: "en6"), keeper, "its own job definition names the keeper")
        expectEqual(ClusterLinkAddressKeeper.described(byJobJSON: reordered, interface: "en6"), keeper, "in any key order")
        for (label, text, interface) in [
            ("for another port", own, "en5"), ("with another interval", LinkFixtures.keeperJobJSON(interface: "en6", address: "169.254.10.20", interval: 60), "en6"),
            ("with an address that is not link-local", own.replacingOccurrences(of: "169.254.10.20", with: "192.0.2.10"), "en6"),
            ("with another program", reordered.replacingOccurrences(of: "/bin/sh", with: "/bin/zsh"), "en6"),
            ("with a longer script", reordered.replacingOccurrences(of: " alias\"", with: " alias; /usr/bin/true\""), "en6"),
            ("that is not JSON", "unexpected text\n", "en6"), ("that is empty", "{}", "en6"),
        ] {
            expect(ClusterLinkAddressKeeper.described(byJobJSON: text, interface: interface) == nil, "a job definition \(label) is nobody's keeper")
        }

        let tools: [ClusterLinkToolCommand] = [.keeperJob(interface: "en6"), .keeperJobFile(interface: "en6"), .keeperJobFileList]
        expectEqual(tools.map(\.executable), ["/bin/launchctl", "/usr/bin/plutil", "/bin/ls"], "read-only keeper tools")
        expectEqual(tools.map(\.arguments), [["print", "system/io.darkbloom.cluster-link.en6"],
            ["-convert", "json", "-o", "-", path], ["/Library/LaunchDaemons"]], "read-only keeper arguments")
    }

    static func privilegedRequests() {
        typealias Request = ClusterLinkPrivilegedRequest
        guard let address = ClusterLinkLocalAddress(dottedDecimal: "169.254.10.20"),
              let keeper = ClusterLinkAddressKeeper(interface: "en6", address: address) else { expect(false, "fixture address"); return }

        let add = Request(.addAddress, interface: "en6", address: address)
        expectEqual(add?.commands, ["/sbin/ifconfig en6 inet 169.254.10.20 netmask 255.255.0.0 alias"], "temporary address command")
        expectEqual(add?.prompt, "Darkbloom wants to give Thunderbolt port en6 its own address so RDMA can use it.", "temporary address prompt")
        expectEqual(add?.appleScript, "do shell script \"/sbin/ifconfig en6 inet 169.254.10.20 netmask 255.255.0.0 alias\" "
            + "with prompt \"Darkbloom wants to give Thunderbolt port en6 its own address so RDMA can use it.\" "
            + "with administrator privileges", "temporary address script")
        expectEqual(add?.manualCommands, ["sudo /sbin/ifconfig en6 inet 169.254.10.20 netmask 255.255.0.0 alias"], "manual temporary command")

        // The durable fix is the keeper's installation: its first run adds the address.
        let keep = Request(.keepAddress, interface: "en6", address: address)
        expectEqual(keep?.commands, keeper.installCommands, "durable fix commands")
        expectEqual(keep?.shellCommand, keeper.installCommands.joined(separator: " && "), "one command line, stopping at the first failure")
        expectEqual(keep?.prompt, "Darkbloom wants to give Thunderbolt port en6 its own address and keep it there so RDMA can use it.",
            "durable fix prompt")
        expectEqual(keep?.manualCommands.count, keeper.installCommands.count, "one manual line per command")
        expectEqual(keep?.manualCommands.first, "sudo /bin/launchctl bootout system/io.darkbloom.cluster-link.en6 2>/dev/null || true",
            "manual lines are the commands under sudo")

        // Removal undoes what is there, the job before the address it would put back.
        let path = "/Library/LaunchDaemons/io.darkbloom.cluster-link.en6.plist"
        let fullRemoval = ["/bin/launchctl bootout system/io.darkbloom.cluster-link.en6", "/bin/rm -f \(path)",
            "/sbin/ifconfig en6 inet 169.254.10.20 -alias"]
        let everything = Request(.remove(.init(address: true, keeperJob: true, keeperFile: true)), interface: "en6", address: address)
        expectEqual(everything?.commands, fullRemoval, "full removal commands")
        expectEqual(everything?.shellCommand, fullRemoval.joined(separator: "; "),
            "a removal runs every command, whatever an earlier one reported")
        expectEqual(everything?.prompt, "Darkbloom wants to remove the address it gave Thunderbolt port en6 and the job that kept it there.",
            "full removal prompt")
        let addressOnly = Request(.remove(.init(address: true)), interface: "en6", address: address)
        expectEqual(addressOnly?.commands, ["/sbin/ifconfig en6 inet 169.254.10.20 -alias"], "address-only removal")
        expectEqual(addressOnly?.prompt, "Darkbloom wants to remove the address it gave Thunderbolt port en6.", "address-only removal prompt")
        let fileOnly = Request(.remove(.init(keeperFile: true)), interface: "en6", address: address)
        expectEqual(fileOnly?.commands, ["/bin/rm -f \(path)"], "a leftover job definition alone")
        expectEqual(fileOnly?.prompt, "Darkbloom wants to remove the job that kept an address on Thunderbolt port en6.",
            "a prompt for the job definition alone names no address")
        // A loaded job may put the address back while the prompt is open, so the address goes with it.
        let strippedPort = Request(.remove(.init(keeperJob: true, keeperFile: true)), interface: "en6", address: address)
        expectEqual(strippedPort?.commands, fullRemoval, "a loaded job is removed together with the address it adds")
        expectEqual(strippedPort?.prompt, everything?.prompt, "and the prompt says so")
        expect(Request(.remove(.init()), interface: "en6", address: address) == nil, "nothing to remove is no request")

        expectEqual(ClusterLinkApproval.executable, "/usr/bin/osascript", "approval tool")
        expectEqual(keep.map(ClusterLinkApproval.arguments(for:)), keep.map { ["-e", $0.appleScript] }, "one script argument, no shell")

        // No hostile text can become part of a privileged command: the type
        // refuses to exist for it, whatever the purpose.
        let purposes: [Request.Purpose] = [.addAddress, .keepAddress, .remove(.init(address: true, keeperJob: true, keeperFile: true))]
        for name in hostileNames {
            for purpose in purposes {
                expect(Request(purpose, interface: name, address: address) == nil, "no \(purpose) request for interface \(name.debugDescription)")
            }
            expect(ClusterLinkName.interface(ofDevice: "rdma_" + name) == nil, "no interface for device rdma_\(name.debugDescription)")
        }

        // Whatever valid parts it is built from, the script has one fixed shape:
        // one quoted command line, one quoted sentence, nothing that needs escaping.
        let shape = #"^do shell script "[A-Za-z0-9 ./:;|&>'_-]+" with prompt "[A-Za-z0-9 ]+\." with administrator privileges$"#
        for interface in ["en6", "en12", "bridge0", "E", String(repeating: "e", count: 15)] {
            for third in [UInt8(1), 127, 254] {
                for purpose in purposes {
                    guard let address = ClusterLinkLocalAddress(third: third, fourth: 254 - third + 1),
                          let request = Request(purpose, interface: interface, address: address) else {
                        expect(false, "valid request for \(interface)"); continue
                    }
                    let script = request.appleScript
                    expect(script.range(of: shape, options: .regularExpression) != nil, "script shape for \(interface), \(purpose)")
                    expect(script.filter { $0 == "\"" }.count == 4 && !script.contains("\\") && !script.contains("\n"),
                        "script quoting for \(interface), \(purpose)")
                    // Single quotes only ever wrap the keeper's script, which has none of its own:
                    // once as the job's argument and once where the script itself is run.
                    expect(script.filter { $0 == "'" }.count == (purpose == .keepAddress ? 4 : 0), "single quotes for \(interface), \(purpose)")
                    for command in request.commands {
                        expect(command.hasPrefix("/"), "\(command.prefix(24))… starts with an absolute path")
                    }
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
