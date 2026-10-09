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
        static let ipv4 = ["192.0.2.10", "198.51.100.7", "169.254.188.90", "10.0.0.1", "255.255.0.0"]
        static let ipv6 = ["fe80::200:5eff:fe00:5307", "2001:db8::7", "::ffff:192.0.2.10", "fe80:0000:0000:0000:0200:5eff:fe00:5307",
                           "2001:0db8:85a3:0000:0000:8a2e:0370:7334", "::1", "fe80::1%en6"]
        static let mac = ["02:00:5e:00:53:07", "0:1:2:a:b:c", "AA:BB:CC:DD:EE:FF"]
        static let publicKey = "AAAAC3NzaC1lZDI1NTE5AAAAIFixtureKeyMaterialFixtureKeyMaterial0000"
        static let fingerprint = "SHA256:" + String(repeating: "Zk9", count: 14) + "A"
        static let privateKey = "-----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW\nFIXTUREPRIVATEBODY\n-----END OPENSSH PRIVATE KEY-----"

        static let identifiers = ClusterDiagnosticRedaction.Identifiers(homeDirectories: [home], userNames: [user, fullName, peerUser],
            hostNames: [host, host + ".local", peerHost], serials: [serial, hardwareUUID], secrets: [token])

        /// Everything that must be gone from any redacted text.
        static let forbidden: [String] = [home, fullName, host, peerHost, peerUser, serial, hardwareUUID, token, publicKey,
            fingerprint, "FIXTUREPRIVATEBODY", "b3BlbnNzaC1rZXk", "hunter2secret", "s3cr3t-bearer-value"] + ipv4 + ipv6 + mac
    }

    private static let redactor = ClusterDiagnosticRedaction(identifiers: Secret.identifiers)

    private static func expectClean(_ text: String, _ what: String, line: Int = #line) {
        let lowered = text.lowercased()
        for value in Secret.forbidden {
            expect(!lowered.contains(value.lowercased()), "\(what): \(value) survived redaction", line: line)
        }
        // The user's name as a word of its own, wherever it appeared.
        expect(lowered.range(of: "(?<![a-z0-9])avery(?![a-z0-9])", options: .regularExpression) == nil, "\(what): the user name survived", line: line)
        expectEqual(redactor.residue(in: text), [], "\(what): the redactor's own check found something", line: line)
    }

    static func redaction() throws {
        let redaction = redactor
        let samples: [String] = [
            "Listening on 192.0.2.10:8000; connection details: darkbloom local",
            "JACCL_COORDINATOR=169.254.188.90:12345 netmask 255.255.0.0 gateway 10.0.0.1 peer 198.51.100.7",
            "inet6 fe80::200:5eff:fe00:5307%en6 prefixlen 64 scopeid 0x15",
            "GID[  2]: ::ffff:192.0.2.10 and GID[  0]: fe80:0000:0000:0000:0200:5eff:fe00:5307",
            "global 2001:db8::7 and 2001:0db8:85a3:0000:0000:8a2e:0370:7334 and loopback ::1 and zone fe80::1%en6",
            "ether 02:00:5e:00:53:07 and 0:1:2:a:b:c and AA:BB:CC:DD:EE:FF",
            "Cannot open installed input at /Users/avery/Library/Application Support/darkbloom/worker (errno 2)",
            "model directory /Users/avery/models/qwen and config ~/.config",
            "ssh clusterop@bench-mac-b.example-lab.net -p 22 failed; known host bench-mac-b.example-lab.net",
            "host averys-studio.local (Averys-Studio) user avery full name Avery Example",
            "IOPlatformSerialNumber\" = \"C02FIXTURE99\"  Serial Number: C02FIXTURE99  serial=C02FIXTURE99",
            "Hardware UUID: 0A1B2C3D-4E5F-6071-8293-A4B5C6D7E8F9 IOPlatformUUID = 0a1b2c3d-4e5f-6071-8293-a4b5c6d7e8f9",
            "known_hosts: bench-mac-b.example-lab.net ssh-ed25519 \(Secret.publicKey) comment",
            "peer host key \(Secret.fingerprint) (ED25519)",
            Secret.privateKey,
            "Authorization: Bearer s3cr3t-bearer-value and token \(Secret.token)",
            "{\"api_key\":\"hunter2secret\",\"base_url\":\"http://192.0.2.10:8000/v1\",\"host\":\"192.0.2.10\"}",
            "nested {\\\"api_key\\\":\\\"hunter2secret\\\",\\\"password\\\": \\\"hunter2secret\\\"}",
            "password=hunter2secret token = hunter2secret apiKey=hunter2secret",
            "mail avery@averys-studio.local or other.person@example.org",
            "another home /Users/someoneelse/Desktop and /home/builder/work and /var/root/.ssh",
        ]
        for sample in samples {
            let redacted = redaction.redact(sample)
            expectClean(redacted, "sample \"\(sample.prefix(40))\"")
            expect(redacted != sample, "nothing was removed from: \(sample.prefix(60))")
        }
        let together = redaction.redact(samples.joined(separator: "\n"))
        expectClean(together, "all samples together")
        expectEqual(redaction.redact(together), together, "redaction is stable when applied twice")
        for placeholder in ["<ipv4>", "<ipv6>", "<mac>", "<host>", "<user>", "<serial>", "<secret>", "<private-key>", "<public-key>", "SHA256:<fingerprint>", "~/Library"] {
            expect(together.contains(placeholder), "the placeholder \(placeholder) is missing")
        }
        expect(!together.contains("someoneelse") && !together.contains("builder") && together.contains("/Users/<user>/Desktop"),
            "another user's home directory is redacted too")
        expect(!together.contains("other.person"), "a mail address is redacted")

        // What a report is compared by is kept exactly.
        let kept = [
            "artifact 127de76b4ef82b7aaa0acaac0ee31c784cff066eda64291f521f051469b7c24b",
            "read 2026-10-09T06:45:12Z at 23:41:07",
            "rdma_en7 (en7): ready \u{B7} port active \u{B7} own IPv4 address \u{B7} IPv4-mapped GID published",
            "epoch 11111111-2222-3333-4444-555555555555 rank 1 of cluster fixture-cluster member peer-0",
            "darkbloom 0.9.19, macOS 26.2, collective progress limit 60000 ms, port 8000",
            "Model directory on this Mac: 12 of 12 manifest files present (5.7 GiB in all).",
            "std::string and Foo::bar and ratio 3:2 and step 2: wait",
            "/usr/bin/ibv_devinfo and /opt/darkbloom/bin/darkbloom-cluster-worker and /Volumes/Models/qwen",
        ]
        for text in kept { expectEqual(redaction.redact(text), text, "text with nothing to remove was changed") }

        // Identifiers too short to be safe are ignored rather than shredding the text.
        let short = ClusterDiagnosticRedaction(identifiers: .init(userNames: ["a", "me"], hostNames: ["m"]))
        expectEqual(short.redact("a member named me on m"), "a member named me on m", "one- and two-character identifiers are not applied")
        // A user name inside another word is left alone; as a word it goes.
        let named = ClusterDiagnosticRedaction(identifiers: .init(userNames: ["sam"]))
        expectEqual(named.redact("the same sample for sam, and SAM."), "the same sample for <user>, and <user>.", "user names match whole words, any case")

        // The check the export relies on sees what is left in unredacted text.
        expect(!redaction.residue(in: samples.joined(separator: "\n")).isEmpty, "the residue check missed unredacted text")
        expect(redaction.residue(in: "peer at 192.0.2.10").contains("an IPv4 address"), "the residue check names what it found")
        expect(redaction.residue(in: "fe80::1").contains("an IPv6 address") && redaction.residue(in: "02:00:5e:00:53:07").contains("a MAC address"),
            "the residue check knows addresses by shape")
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
                observation: "Cannot read \(home)/.darkbloom/local.json from averys-studio.local (192.0.2.10)"),
            reference: .success(fixture.reference), paths: fixture.paths, candidate: nil, run: { _ in .unavailable })
        let input = ClusterDiagnosticExport.Input(snapshot: snapshot,
            activity: [.init(time: "06:00:00", title: "Start session", failed: true,
                lines: ["ssh clusterop@bench-mac-b.example-lab.net: Permission denied (publickey).",
                        "identity \(home)/key was offered; host key \(Secret.fingerprint)",
                        "serial number C02FIXTURE99, hardware UUID \(Secret.hardwareUUID)"])],
            sessionState: "ended(\"exited with status 1\")",
            sessionOutput: ["darkbloom 0.9.19 (local / distributed)", "Listening on 192.0.2.10:8000; connection details: darkbloom local",
                            "Authorization: Bearer \(Secret.token)", "worker at \(home)/worker refused fe80::200:5eff:fe00:5307%en6",
                            "ether 02:00:5e:00:53:07", Secret.privateKey],
            darkbloomVersion: "0.9.19")

        let bytes = try ClusterDiagnosticExport.render(input, redaction: redaction, createdAt: "2026-10-09T06:00:00Z")
        let text = String(decoding: bytes, as: UTF8.self)
        for value in [home, "averys-studio", "bench-mac-b", "clusterop", "peer-1.local", "peer-0.local", "192.0.2.10", "192.168.2.1",
                      "fe80::200", "02:00:5e:00:53:07", Secret.serial, Secret.hardwareUUID, Secret.token, Secret.fingerprint,
                      "FIXTUREPRIVATEBODY", "synthetic-private-key-fixture"] {
            expect(!text.lowercased().contains(value.lowercased()), "the export still contains \(value)")
        }
        expectEqual(redaction.residue(in: text), [], "the export passes its own residue check")
        let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any]
        expectEqual(object?["schema"] as? String, ClusterDiagnosticExport.schemaName, "the export is one JSON document with its schema")
        expect((object?["snapshot"] as? [String: Any])?["schema"] as? String == ClusterConsoleSnapshot.schemaName, "it holds the snapshot")
        expect((object?["redaction"] as? String)?.contains("removed") == true, "it says what was removed")
        // What makes the report useful is still there.
        for value in ["portBridgedWithoutAddress", "installed-fixture", "rdma_en6", fixture.reference.sha256, "Permission denied (publickey)",
                      "exited with status 1", "0.9.19", "<ipv4>:8000", "Bearer <secret>", "SHA256:<fingerprint>", "<user>@<host>"] {
            expect(text.contains(value), "the export lost \(value)")
        }

        // Even before redaction, the snapshot itself holds no host, user, address or path.
        let unmarked = ClusterConsoleObserver.snapshot(link: ConsoleFixtures.bridgedLink, diagnostics: ConsoleFixtures.diagnostics(link: ConsoleFixtures.bridgedLink),
            reference: .success(fixture.reference), paths: fixture.paths, candidate: nil, run: { _ in .unavailable })
        let raw = String(decoding: try JSONEncoder().encode(unmarked), as: UTF8.self)
        for value in ["peer-1.local", "peer-0.local", "192.168.2.1", "\"fixture\"", scratch.lastPathComponent, "known_hosts", "/key"] {
            expect(!raw.contains(value), "the snapshot carries \(value) before any redaction")
        }

        // The file: owner-only, never replacing one that exists.
        let directory = scratch.appendingPathComponent("export-out")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let moment = Date(timeIntervalSince1970: 1_791_000_000)
        let file = try ClusterDiagnosticExport.write(input, redaction: redaction, directory: directory, now: moment)
        var information = stat()
        expect(lstat(file.path, &information) == 0 && information.st_mode & 0o777 == 0o600, "the export is owner-only")
        expect(file.lastPathComponent.hasPrefix("darkbloom-cluster-diagnostics-") && file.pathExtension == "json", "the file is named for what it is")
        let written = try Data(contentsOf: file)
        expect(!String(decoding: written, as: UTF8.self).contains(home), "the written file is the redacted one")
        var refusal = ""
        do { _ = try ClusterDiagnosticExport.write(input, redaction: redaction, directory: directory, now: moment) } catch { refusal = String(describing: error) }
        let afterRefusal = try Data(contentsOf: file)
        expect(refusal.contains("already exists") && afterRefusal == written, "a second export in the same second replaces nothing")

        // A redactor that does not know an identifier cannot produce a file that carries an address.
        let blind = ClusterDiagnosticRedaction(identifiers: .init())
        let blindText = String(decoding: try ClusterDiagnosticExport.render(input, redaction: blind, createdAt: "2026-10-09T06:00:00Z"), as: UTF8.self)
        for value in ["192.0.2.10", "fe80::200", "02:00:5e:00:53:07", Secret.token, "FIXTUREPRIVATEBODY", home] {
            expect(!blindText.contains(value), "with no identifiers known, \(value) still must not survive")
        }
    }
}
