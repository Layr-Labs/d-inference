import Foundation
import Darwin
@testable import InstalledContract

extension ClusterConsoleCheck {
    /// Made-up values of every kind the export must not carry. None belongs
    /// to a real machine; the addresses are documentation ranges.
    private enum Secret {
        static let home = "/Users/avery"
        static let user = "avery"
        static let fullName = "Avery Example"
        static let host = "averys-studio"
        static let peerHost = "bench-mac-b.example-lab.net"
        static let peerUser = "clusterop"
        static let serial = "C02FIXTURE99"
        static let hardwareUUID = "0A1B2C3D-4E5F-6071-8293-A4B5C6D7E8F9"
        static let token = "dk-local-Zm9vYmFyYmF6cXV4MTIzNDU2Nzg5MA"
        static let ipv4 = ["192.0.2.10", "198.51.100.7", "169.254.188.90", "10.0.0.1", "255.255.0.0", "169.254.12.7", "10.0.0.5"]
        static let ipv6 = ["fe80::200:5eff:fe00:5307", "2001:db8::7", "::ffff:192.0.2.10", "fe80:0000:0000:0000:0200:5eff:fe00:5307",
                           "2001:0db8:85a3:0000:0000:8a2e:0370:7334", "fe80::1%en6", "fe80::1c2d:3e4f", "5eff:fe00:5307"]
        static let mac = ["02:00:5e:00:53:07", "0:1:2:a:b:c", "AA:BB:CC:DD:EE:FF", "02-00-5e-00-53-07", "0200.5e00.5307"]
        static let publicKey = "AAAAC3NzaC1lZDI1NTE5AAAAIFixtureKeyMaterialFixtureKeyMaterial0000"
        static let fingerprint = "SHA256:" + String(repeating: "Zk9", count: 14) + "A"
        static let privateKey = "-----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW\nFIXTUREPRIVATEBODY\n-----END OPENSSH PRIVATE KEY-----"
        /// The end of a key whose first lines scrolled out of what was kept.
        static let keyTail = "QyNTUxOQAAACBmaXh0dXJlLWtleS10YWlsLWJvZHktMDEyMzQ1Njc4OWFiY2RlZgAAAE\nAAAECfixtureTAILbody0123456789fixtureTAILbody0123456789abcdEFGH==\n-----END OPENSSH PRIVATE KEY-----"
        /// A line from the middle of one, with neither its beginning nor its end.
        static let keyMiddle = "b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW"

        static let identifiers = ClusterDiagnosticRedaction.Identifiers(homeDirectories: [home], userNames: [user, fullName, peerUser],
            hostNames: [host, host + ".local", peerHost], serials: [serial, hardwareUUID], secrets: [token])

        /// Everything that must be gone from any redacted text.
        static let forbidden: [String] = [home, fullName, host, peerHost, peerUser, serial, hardwareUUID, token, publicKey,
            fingerprint, "FIXTUREPRIVATEBODY", "b3BlbnNzaC1rZXk", "fixtureTAILbody", "QyNTUxOQ", "hunter2", "s3cr3t-bearer-value",
            "Clients", "AcmeCorp", "someoneelse", "builder", "ZoeSSD", "Zoe", "other.person", "remote-box", "example-lab",
            "setup-secret-name", "untitled", "Passport", "build7", "corp.example", "admin", "p%40ss", "eyJhbGci", "Zm9v-YmFy",
            "0c42:a103", "192.168.001.010", "AbCdEfGhIjKlMnOpQrSt", "254.7.9", "52100"]
            + ipv4 + ipv6 + mac
    }

    private static let redactor = ClusterDiagnosticRedaction(identifiers: Secret.identifiers)

    private static func expectClean(_ text: String, _ what: String, line: Int = #line) {
        let redacted = redactor.redact(text), lowered = redacted.lowercased()
        for value in Secret.forbidden {
            expect(!lowered.contains(value.lowercased()), "\(what): \(value) survived redaction in: \(redacted.prefix(160))", line: line)
        }
        // The user's name as a word of its own, wherever it appeared.
        expect(lowered.range(of: "(?<![a-z0-9])avery(?![a-z0-9])", options: .regularExpression) == nil, "\(what): the user name survived", line: line)
        // The second look, which shares no rule with the first.
        expectEqual(redactor.residue(inMarked: redactor.marked(text)), [], "\(what): the second look still recognizes something", line: line)
        expect(redacted != text, "\(what): nothing was removed", line: line)
    }

    static func redaction() throws {
        let samples: [String] = [
            "Listening on 192.0.2.10:8000; connection details: darkbloom local",
            "JACCL_COORDINATOR=169.254.188.90:12345 netmask 255.255.0.0 gateway 10.0.0.1 peer 198.51.100.7",
            // Addresses as sentences leave them: before a full stop, after a label, in brackets.
            "Could not connect to 169.254.12.7. Retrying.",
            "mapped ::ffff:10.0.0.5. and [2001:db8::7]:8000 and <198.51.100.7>",
            "No route to fe80::1c2d:3e4f.",
            "addr:fe80::1c2d:3e4f GID:fe80:0000:0000:0000:0200:5eff:fe00:5307 src=2001:db8::7",
            "inet6 fe80::200:5eff:fe00:5307%en6 prefixlen 64 scopeid 0x15",
            "GID[  2]: ::ffff:192.0.2.10 and GID[  0]: fe80:0000:0000:0000:0200:5eff:fe00:5307",
            "global 2001:db8::7 and 2001:0db8:85a3:0000:0000:8a2e:0370:7334 and zone fe80::1%en6",
            "ether 02:00:5e:00:53:07 and 0:1:2:a:b:c and AA:BB:CC:DD:EE:FF and 02-00-5e-00-53-07 and 0200.5e00.5307",
            // Paths: under the home, with spaces, with escaped slashes, another user's, a volume.
            "Cannot open installed input at /Users/avery/Library/Application Support/darkbloom/worker (errno 2)",
            "model directory /Users/avery/Clients/AcmeCorp/models/qwen and config /Users/avery/.config",
            "{\\\"path\\\":\\\"\\/Users\\/avery\\/Clients\\/AcmeCorp\\\"}",
            "another home /Users/someoneelse/Desktop and /users/someoneelse/x and /home/builder/work and /var/root/.ssh",
            "weights on /Volumes/ZoeSSD/models and home /Users/Zoe Smith/Library/x",
            // Hosts and users: literal, by ending, by where they stand.
            "ssh clusterop@bench-mac-b.example-lab.net -p 22 failed; known host bench-mac-b.example-lab.net",
            "host averys-studio.local (Averys-Studio) user avery full name Avery Example",
            "ssh: connect to host remote-box.example-lab.net port 22: Operation timed out; peer: remote-box.example-lab.net",
            "mail avery@averys-studio.local or other.person@example.org",
            // Serial numbers.
            "IOPlatformSerialNumber\" = \"C02FIXTURE99\"  Serial Number: C02FIXTURE99  serial=C02FIXTURE99",
            "Hardware UUID: 0A1B2C3D-4E5F-6071-8293-A4B5C6D7E8F9 IOPlatformUUID = 0a1b2c3d-4e5f-6071-8293-a4b5c6d7e8f9",
            // Keys, whole and in pieces.
            "known_hosts: bench-mac-b.example-lab.net ssh-ed25519 \(Secret.publicKey) comment",
            "peer host key \(Secret.fingerprint) (ED25519)",
            Secret.privateKey,
            Secret.keyTail,
            Secret.keyMiddle,
            // Credentials under every name and quoting they come in.
            "Authorization: Bearer s3cr3t-bearer-value and token \(Secret.token)",
            "Authorization: Basic aHVudGVyMjpodW50ZXIy and x-api-key: hunter2secret and password: hunter2secret",
            "{\"api_key\":\"hunter2secret\",\"base_url\":\"http://192.0.2.10:8000/v1\",\"host\":\"192.0.2.10\"}",
            "{\"access_token\":\"hunter2secret\",\"authToken\":\"hunter2secret\",\"client_secret\":\"hunter2secret\"}",
            "{\"password\":\"hunter2\\\"hunter2\"}",
            "nested {\\\"api_key\\\":\\\"hunter2secret\\\",\\\"password\\\": \\\"hunter2secret\\\"}",
            "doubly nested {\\\\\\\"api_key\\\\\\\":\\\\\\\"hunter2secret\\\\\\\"}",
            "password=hunter2secret token = hunter2secret apiKey=hunter2secret auth_token=hunter2secret",
            // A bare name with a quoted value, as a value's description prints it, and a flag with its value.
            "Config(apiKey: \"hunter2secret\", password=\"hunter2 secret\", token = 'hunter2secret')",
            "darkbloom login --token hunter2secret --api-key hunter2secret",
            // A login in a URL, a host no setup names, a signed token and a URL-safe blob with nothing to announce them.
            "GET https://admin:p%40ss!word@10.0.0.5/x and https://build7.corp.example.com:8443/v1/models failed",
            "id eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJmaXh0dXJlIn0.c2lnbmF0dXJlLWZpeHR1cmU and Zm9v-YmFy_QUJD-REVG_MTIz-NDU2_Z2hp-amts_TU5P-UFFS",
            "last line of a key: AbCdEfGhIjKlMnOpQrSt==",
            // Addresses joined to what stands next to them, with a port after a dot, with leading zeros.
            "mac:aa:bb:cc:dd:ee:ff up and ether 02:00:5e:00:53:07: flags",
            "tcp4 0 0 10.0.0.1.52100 198.51.100.7.443 ESTABLISHED and 192.168.001.010",
            "node_guid: 0c42:a103:0045:6f12 sys_image_guid: 0c42:a103:0045:6f12",
            // Paths with a space before a small letter, under ~, and under another user's home, whole.
            "opened /Users/avery/Desktop/untitled folder/setup-secret-name.json and ~/Clients/AcmeCorp/key",
            "peer path /Users/someoneelse/Clients/AcmeCorp/key and /Volumes/My Passport/models/x and more",
        ]
        for sample in samples { expectClean(sample, "sample \"\(sample.prefix(48))\"") }
        let together = redactor.redact(samples.joined(separator: "\n"))
        expectClean(samples.joined(separator: "\n"), "all samples together")
        for placeholder in ["<ipv4>", "<ipv6>", "<mac>", "<host>", "<user>", "<serial>", "<secret>", "<private-key>", "<public-key>",
                            "SHA256:<fingerprint>", "<home-path>", "/Volumes/<volume>", "<encoded>", "<user>@<host>",
                            "another home <home-path> and <home-path> and <home-path> and <home-path>",
                            "weights on /Volumes/<volume> and home <home-path>", "opened <home-path> and <home-path>",
                            "peer path <home-path> and /Volumes/<volume> and more", "https://<secret>@<ipv4>/x and https://<host>:8443/v1/models",
                            "apiKey: \"<secret>\", password=\"<secret>\", token = '<secret>'", "--token <secret> --api-key <secret>",
                            "mac:<mac> up and ether <mac>: flags", "tcp4 0 0 <ipv4> <ipv4> ESTABLISHED and <ipv4>", "node_guid: <mac> sys_image_guid: <mac>",
                            "<ipv4>:8000", "[<ipv6>]:8000", "to <ipv4>. Retrying.", "No route to <ipv6>.", "addr:<ipv6> GID:<ipv6> src=<ipv6>",
                            "Cannot open installed input at <home-path> (errno 2)", "and config <home-path>"] {
            expect(together.contains(placeholder), "expected \(placeholder) in the redacted text")
        }
        expect(!together.unicodeScalars.contains { (0xE000...0xF8FF).contains($0.value) }, "no internal mark is left in the result")

        // What a report is compared by is kept exactly.
        let kept = [
            "artifact 127de76b4ef82b7aaa0acaac0ee31c784cff066eda64291f521f051469b7c24b",
            "read 2026-10-09T06:45:12Z at 23:41:07",
            "rdma_en7 (en7): ready \u{B7} port active \u{B7} own IPv4 address \u{B7} IPv4-mapped GID published",
            "epoch 11111111-2222-3333-4444-555555555555 rank 1 of cluster fixture-cluster member peer-0",
            "darkbloom 0.9.19, macOS 26.2, collective progress limit 60000 ms, port 8000",
            "Model directory on this Mac: 12 of 12 manifest files present (5.7 GiB in all).",
            "std::string and Foo::bar and ratio 3:2 and step 2: wait",
            "/usr/bin/ibv_devinfo and /opt/darkbloom/bin/darkbloom-cluster-worker",
            "Local leader: host serving, session ready, ready, admission available, port 8000, bearer authentication.",
            "Lifetime remaining 281 s; admissions remaining 15; maximumPromptTokens 8192; tokenizer.json verified.",
            "Sources/ProviderCore/Inference/Distributed/Console/ClusterConsoleLiveOperations.swift",
            "The peer is peer-1 (rank 1); this Mac is peer-0 (leader, rank 0) on rdma_en7.",
            "Wrote darkbloom-cluster-diagnostics-20261009T093307Z.json in the directory this command was run in.",
            "  /bin/launchctl bootstrap system /Library/LaunchDaemons/io.darkbloom.cluster-link.en6.plist",
            "registered_qwen38_27b (qwen35-dense-layer-stage v1), profile registered_qwen38_27b_greedy_generation_v1",
            "OID 1.3.6.1.4.1.311 and macOS 14.6.1 and http://localhost:8000/v1/cluster/status and /home/ alone",
        ]
        for text in kept {
            expectEqual(redactor.redact(text), text, "text with nothing to remove was changed")
            expectEqual(redactor.residue(inMarked: redactor.marked(text)), [], "the second look objects to text with nothing in it")
        }

        // Identifiers too short to be safe are ignored rather than shredding the text.
        let short = ClusterDiagnosticRedaction(identifiers: .init(userNames: ["a", "me"], hostNames: ["m"]))
        expectEqual(short.redact("a member named me on m"), "a member named me on m", "one- and two-character identifiers are not applied")
        // A user name inside another word is left alone; as a word it goes.
        let named = ClusterDiagnosticRedaction(identifiers: .init(userNames: ["sam"]))
        expectEqual(named.redact("the same sample for sam, and SAM."), "the same sample for <user>, and <user>.", "user names match whole words, any case")

        // An identifier that is also a placeholder's word neither mangles the placeholders nor blocks an export.
        let awkward = ClusterDiagnosticRedaction(identifiers: .init(homeDirectories: ["/Users/user"], userNames: ["user", "host", "secret"],
            hostNames: ["Mac", "ipv4"]))
        let awkwardText = "user at /Users/user/x and /Users/other on this Mac at 192.0.2.10 with token=abc123 from host"
        expectEqual(awkward.redact(awkwardText), "<user> at <home-path> and <home-path> on this <host> at <ipv4> with token=<secret> from <user>",
            "identifiers equal to placeholder words are replaced once and the placeholders stay whole")
        expectEqual(awkward.residue(inMarked: awkward.marked(awkwardText)), [], "and the second look does not mistake a placeholder for what it replaced")

        // A name that is also part of an address must not split the address: a peer whose
        // host is an address was once known by that address's first number too.
        let numbered = ClusterDiagnosticRedaction(identifiers: .init(hostNames: ["169.254.12.7", "169", "100", "255"]))
        let command = "  /sbin/ifconfig en6 inet 169.254.7.9 netmask 255.255.0.0 alias; peer 169.254.12.7 and 100 requests"
        expectEqual(numbered.redact(command), "  /sbin/ifconfig en6 inet <ipv4> netmask <ipv4> alias; peer <ipv4> and 100 requests",
            "an address is replaced whole before any name, and a bare number is never a name")
        expectEqual(numbered.residue(inMarked: numbered.marked(command)), [], "and the second look finds nothing left of it")

        // A private-use character already in the text cannot pose as a mark.
        expect(!redactor.redact("forged \u{E000} mark").contains("<ipv4>"), "a forged mark is not spelled out as a placeholder")

        // The second look sees what is left in text nobody redacted, by its own means.
        let mark = ClusterDiagnosticRedaction.Mark.host.character
        for (text, expected) in [("peer at 192.0.2.10.", "an IPv4 address"), ("route fe80::1.", "an IPv6 address"), ("GID:fe80:0000:0000:0000:0200:5eff:fe00:5307", "an IPv6 address"),
                                 ("inet \(mark).254.7.9 netmask", "part of an IPv4 address"), ("from 9.7.254.\(mark)", "part of an IPv4 address"),
                                 ("10.0.0.2.52100", "an IPv4 address"), ("192.168.001.010", "an IPv4 address"),
                                 ("mac:aa:bb:cc:dd:ee:ff", "a MAC address"), ("02:00:5e:00:53:07: up", "a MAC address"), ("0c42:a103:0045:6f12", "a hardware identifier"),
                                 ("02:00:5e:00:53:07", "a MAC address"), ("02-00-5e-00-53-07", "a MAC address"), ("0200.5e00.5307", "a MAC address"),
                                 ("on averys-studio now", "a host name"), ("by Avery Example", "a user name"), ("unit C02FIXTURE99", "a serial number"),
                                 ("in /Users/avery/x", "a home directory"), ("in /Users/nobody/x", "a home directory"), (Secret.token, "a credential"),
                                 ("-----BEGIN OPENSSH PRIVATE KEY-----", "a private key"), ("ssh-ed25519 AAAAC3Nza", "a public key")] {
            expect(redactor.residue(inMarked: text).contains(expected), "the second look missed \(expected) in: \(text)")
        }
    }

    static func diagnosticExport() throws {
        // A snapshot from a real fixture setup: its files name a host, a user, an address and paths under a home.
        let fixture = try installedFixture("export")
        let home = fixture.root.path
        let identifiers = ClusterDiagnosticRedaction.Identifiers(homeDirectories: [home], userNames: [Secret.user],
            hostNames: [Secret.host, "peer-0.local", "peer-1.local"], serials: [Secret.serial, Secret.hardwareUUID], secrets: [Secret.token])
        let redaction = ClusterDiagnosticRedaction(identifiers: identifiers)
        let snapshot = ClusterConsoleObserver.snapshot(link: ConsoleFixtures.bridgedLink,
            diagnostics: ConsoleFixtures.diagnostics(link: ConsoleFixtures.bridgedLink,
                observation: "The request to http://192.0.2.10:8000/v1/cluster/status timed out; \(home)/.darkbloom/local.json from averys-studio.local"),
            reference: .success(fixture.reference), paths: fixture.paths, candidate: nil)
        let input = ClusterDiagnosticExport.Input(snapshot: snapshot,
            activity: [.init(time: "06:00:00", title: "Start session", failed: true,
                lines: ["ssh clusterop@bench-mac-b.example-lab.net: Permission denied (publickey).",
                        "identity \(home)/key was offered; host key \(Secret.fingerprint)",
                        "serial number C02FIXTURE99, hardware UUID \(Secret.hardwareUUID)"]),
                // A dry run of the link fix lists its commands, and they name the address.
                .init(time: "06:00:01", title: "Fix link", failed: false,
                    lines: ["Link fix: dryRun", "  /sbin/ifconfig en6 inet 169.254.7.9 netmask 255.255.0.0 alias"])],
            sessionState: "ended(\"exited with status 1\")",
            sessionOutput: ["darkbloom 0.9.19 (local / distributed)", "Listening on 192.0.2.10:8000; connection details: darkbloom local",
                            "Authorization: Bearer \(Secret.token)", "worker at \(home)/worker refused fe80::200:5eff:fe00:5307%en6.",
                            "{\"api_key\":\"hunter2secret\",\"dir\":\"\(home.replacingOccurrences(of: "/", with: "\\/"))\\/models\"}",
                            "ether 02:00:5e:00:53:07", Secret.privateKey, Secret.keyMiddle],
            darkbloomVersion: "0.9.19")

        let bytes = try ClusterDiagnosticExport.render(input, redaction: redaction, createdAt: "2026-10-09T06:00:00Z")
        let text = String(decoding: bytes, as: UTF8.self)
        for value in [home, scratch.lastPathComponent, "averys-studio", "bench-mac-b", "clusterop", "peer-1.local", "peer-0.local", "192.0.2.10", "169.254.7.9",
                      "192.168.2.1", "fe80::200", "02:00:5e:00:53:07", Secret.serial, Secret.hardwareUUID, Secret.token, Secret.fingerprint,
                      "FIXTUREPRIVATEBODY", Secret.keyMiddle, "hunter2", "synthetic-private-key-fixture"] {
            expect(!text.lowercased().contains(value.lowercased()), "the export still contains \(value)")
        }
        let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any]
        expectEqual(object?["schema"] as? String, ClusterDiagnosticExport.schemaName, "the export is one JSON document with its schema")
        expect((object?["snapshot"] as? [String: Any])?["schema"] as? String == ClusterConsoleSnapshot.schemaName, "it holds the snapshot")
        expect((object?["redaction"] as? String)?.contains("removed") == true, "it says what was removed")
        expectEqual((object?["sessionOutput"] as? [String])?.count, input.sessionOutput.count, "every line of session output is still a line")
        // What makes the report useful is still there.
        for value in ["portBridgedWithoutAddress", "installed-fixture", "rdma_en6", fixture.reference.sha256, "Permission denied (publickey)",
                      "exited with status 1", "0.9.19", "<ipv4>:8000", "Bearer <secret>", "SHA256:<fingerprint>", "<user>@<host>", "<home-path>",
                      "/sbin/ifconfig en6 inet <ipv4> netmask <ipv4> alias",
                      "\\\"api_key\\\":\\\"<secret>\\\""] {
            expect(text.contains(value), "the export lost \(value)")
        }

        // The snapshot is clean before any export: what it shows on screen, prints and encodes
        // holds no host, user, address or path, even inside an error an operation worded.
        let raw = String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self) + snapshot.plainLines.joined(separator: "\n")
        for value in ["peer-1.local", "peer-0.local", "192.168.2.1", "192.0.2.10", "\"fixture\"", scratch.lastPathComponent, "known_hosts", "/key",
                      "averys-studio"] {
            expect(!raw.contains(value), "the snapshot carries \(value) before any export")
        }
        expect(raw.contains("The request to http://<ipv4>:8000/v1/cluster/status timed out; <home-path> from <host>"),
            "an operation's error is shown as it was worded, less what identifies the Mac")

        // The file: owner-only, never replacing one that exists.
        let directory = scratch.appendingPathComponent("export-out")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let moment = Date(timeIntervalSince1970: 1_791_000_000)
        let file = try ClusterDiagnosticExport.write(input, redaction: redaction, directory: directory, now: moment)
        var information = stat()
        expect(lstat(file.path, &information) == 0 && information.st_mode & 0o777 == 0o600, "the export is owner-only")
        expect(file.lastPathComponent.hasPrefix("darkbloom-cluster-diagnostics-") && file.pathExtension == "json", "the file is named for what it is")
        let written = try Data(contentsOf: file)
        expectEqual(written, try ClusterDiagnosticExport.render(input, redaction: redaction, createdAt: ClusterConsoleText.timestamp(moment)),
            "the written file is the redacted document")
        var refusal = ""
        do { _ = try ClusterDiagnosticExport.write(input, redaction: redaction, directory: directory, now: moment) } catch { refusal = String(describing: error) }
        let afterRefusal = try Data(contentsOf: file)
        expect(refusal.contains("already exists") && afterRefusal == written, "a second export in the same second replaces nothing")

        // A redactor that knows no identifier still writes no address, key, credential or home path.
        let blind = ClusterDiagnosticRedaction(identifiers: .init())
        let blindText = String(decoding: try ClusterDiagnosticExport.render(input, redaction: blind, createdAt: "2026-10-09T06:00:00Z"), as: UTF8.self)
        for value in ["192.0.2.10", "fe80::200", "02:00:5e:00:53:07", Secret.token, "FIXTUREPRIVATEBODY", Secret.keyMiddle, "hunter2", home] {
            expect(!blindText.contains(value), "with no identifiers known, \(value) still must not survive")
        }

        // If something recognizable were to survive, nothing is written. The first pass is made
        // to miss everything, by a marking that changes nothing, and the second look must refuse.
        let leaking = ClusterDiagnosticExport.Input(snapshot: snapshot, activity: [], sessionState: "none",
            sessionOutput: ["a host name no rule knows by shape: quietbox"], darkbloomVersion: "0.9.19")
        let knowing = ClusterDiagnosticRedaction(identifiers: .init(hostNames: ["quietbox"]))
        expect(!String(decoding: try ClusterDiagnosticExport.render(leaking, redaction: knowing, createdAt: "x"), as: UTF8.self).contains("quietbox"),
            "a known host name is removed")
        var refused: ClusterDiagnosticExport.Failure?
        do { _ = try ClusterDiagnosticExport.render(leaking, redaction: knowing, createdAt: "x", marking: { $0 }) }
        catch let failure as ClusterDiagnosticExport.Failure { refused = failure }
        expectEqual(refused?.description, "The export was not written: after redaction it still contained a host name.",
            "an export the first pass left a name in is refused by the second look, which names what it recognized")
        let faulty = ClusterDiagnosticExport.Input(snapshot: snapshot, activity: [], sessionState: "none",
            sessionOutput: ["ether 02:00:5e:00:53:07 on 192.0.2.10"], darkbloomVersion: "0.9.19")
        var refusedShapes: ClusterDiagnosticExport.Failure?
        do { _ = try ClusterDiagnosticExport.render(faulty, redaction: blind, createdAt: "x", marking: { $0 }) }
        catch let failure as ClusterDiagnosticExport.Failure { refusedShapes = failure }
        expectEqual(refusedShapes?.description, "The export was not written: after redaction it still contained a MAC address, an IPv4 address.",
            "and so is one with an address left in it, by shape alone")

        // A schema's name is the document's own: a user who shares a word with it does not rewrite it.
        let namesake = ClusterDiagnosticRedaction(identifiers: .init(userNames: ["darkbloom", "cluster"]))
        let own = try JSONSerialization.jsonObject(with: ClusterDiagnosticExport.render(input, redaction: namesake, createdAt: "x")) as? [String: Any]
        expect(own?["schema"] as? String == ClusterDiagnosticExport.schemaName
            && (own?["snapshot"] as? [String: Any])?["schema"] as? String == ClusterConsoleSnapshot.schemaName, "schema names pass through unchanged")
    }
}
