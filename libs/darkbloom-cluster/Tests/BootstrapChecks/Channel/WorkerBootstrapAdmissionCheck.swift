import Darwin
import DarkbloomClusterSecurity
import Foundation

enum AdmissionTestFailure: Error { case failed(String) }

@main enum WorkerBootstrapAdmissionCheck {
    static func main() throws {
        let now: UInt64 = 1_000_000_000, lifetime: UInt64 = 101_000_000_000
        let base = ["--model-dir", "/not-read", "--rank", "0", "--stage-cut", "4",
            "--membership-epoch", "550e8400-e29b-41d4-a716-446655440000",
            "--model-id", "registered_qwen35_9b", "--artifact-sha256", String(repeating: "a", count: 64),
            "--configuration-sha256", String(repeating: "b", count: 64),
            "--peer0-id", "host-a", "--peer0-build-sha256", String(repeating: "c", count: 64),
            "--peer1-id", "host-b", "--peer1-build-sha256", String(repeating: "d", count: 64),
            "--deadline-uptime-nanoseconds", String(lifetime)]
        let extra = ["--bootstrap-socket-path", "/private/tmp/owned/channel", "--bootstrap-owner-pid", "123",
            "--bootstrap-deadline-uptime-nanoseconds", String(lifetime - 1)]
        var accepted = 0, rejected = 0
        func check(_ value: Bool, _ message: String) throws { if !value { throw AdmissionTestFailure.failed(message) } }
        func replacing(_ arguments: [String], _ flag: String, _ value: String) -> [String] {
            var result = arguments; result[result.firstIndex(of: flag)! + 1] = value; return result
        }
        func refuse(_ arguments: [String]) throws {
            do { _ = try WorkerConfiguration(arguments: arguments, now: now) }
            catch { rejected += 1; return }
            throw AdmissionTestFailure.failed("Malformed worker arguments accepted")
        }
        for cut in [4, 8, 12, 16] {
            let value = try WorkerConfiguration(arguments: replacing(base, "--stage-cut", String(cut)), now: now)
            try check(value.bootstrap == nil && value.load.stageCut == cut && value.load.deadlineUptimeNanoseconds == lifetime,
                "Legacy default changed")
            accepted += 1
        }
        try check(try WorkerConfiguration(arguments: base, now: now).load.prefillSchedule == .serial,
            "Omitted worker schedule changed")
        for schedule in ["serial_v1", "one_chunk_lookahead_v1"] {
            for attachment in [[], extra] {
                let value = try WorkerConfiguration(arguments: base + ["--prefill-schedule", schedule] + attachment, now: now)
                try check(value.load.prefillSchedule.rawValue == schedule, "Explicit worker schedule changed")
                accepted += 1
            }
        }
        for malformed in ["", "serial", "oneChunkLookahead", "SERIAL_V1", "unknown", "1", "serial_v1 "] {
            try refuse(base + ["--prefill-schedule", malformed])
        }
        try refuse(base + ["--prefill-schedule", "serial_v1", "--prefill-schedule", "one_chunk_lookahead_v1"])
        try refuse(base + ["--prefill-schedule", "serial_v1", "--bootstrap-owner-pid", "123"])
        let attached = try WorkerConfiguration(arguments: base + extra, now: now)
        try check(attached.bootstrap?.ownerProcessID == 123 && attached.bootstrap?.deadlineUptimeNanoseconds == lifetime - 1,
            "Attachment identity changed")
        try check(attached.load.identity.membershipEpoch.uuidString.lowercased() == base[7]
            && attached.load.rank == 0 && attached.load.identity.peers.map(\.id) == ["host-a", "host-b"], "Load identity changed")
        accepted += 1
        for count in [1, 2] { try refuse(base + Array(extra.prefix(count * 2))) }
        for index in stride(from: 0, to: extra.count, by: 2) {
            var missing = extra; missing.removeSubrange(index...index + 1); try refuse(base + missing)
        }
        try refuse(base + extra + ["--bootstrap-owner-pid", "123"])
        var duplicate = base + extra; duplicate[24] = "--rank"; try refuse(duplicate)
        var missingBase = base + extra; missingBase[0] = "--unknown"; try refuse(missingBase)
        for value in ["0", "1", "-1", "0123", "2147483648"] {
            try refuse(replacing(base + extra, "--bootstrap-owner-pid", value))
        }
        // The bootstrap may outlast the first lease grant (the lease is renewed
        // while the worker loads and joins its peer), but not the hour.
        _ = try WorkerConfiguration(arguments: replacing(base + extra, "--bootstrap-deadline-uptime-nanoseconds", String(lifetime + 1)), now: now)
        accepted += 1
        for value in [String(now), String(now + 3_600_000_000_001), "0" + String(lifetime), "-1"] {
            try refuse(replacing(base + extra, "--bootstrap-deadline-uptime-nanoseconds", value))
        }
        for value in ["relative", "/" + String(repeating: "a", count: 103), "/bad\0path"] {
            try refuse(replacing(base + extra, "--bootstrap-socket-path", value))
        }
        // The committed native start (S07) is admitted only with the complete
        // attachment and only as one canonical encoded start. Fixture digests.
        func digest(_ byte: UInt8) -> Data { Data(repeating: byte, count: 32) }
        let common = try ClusterNativeAuthorizationCommon(epoch: UUID(uuidString: base[7])!, membershipGeneration: 1,
            nativePolicyGeneration: 1, membershipTranscriptSHA256: digest(0x11), approvedNativeBindingSHA256: digest(0x12),
            planSHA256: digest(0x21), artifactSHA256: digest(0xaa), nativeRuntimeSHA256: digest(0x13),
            capabilitySHA256: digest(0x14), resourcePolicySHA256: digest(0x15), profileSHA256: digest(0x16), schedule: .serial,
            maximumTransportFrameBytes: (1 << 20) + 40, limits: try ClusterRecordLimits(maximumPlaintextBytes: 1 << 20))
        let start = try ClusterNativeAuthorizationStart(common: common, rank: 0, ownerIncarnation: UUID(), leaseID: UUID(), launchID: UUID())
        let flag = "--native-authorization-start-base64", text = start.canonicalBytes.base64EncodedString()
        let started = try WorkerConfiguration(arguments: base + extra + [flag, text], now: now)
        try check(started.bootstrap?.nativeStart == start.canonicalBytes && started.bootstrap?.ownerProcessID == 123,
            "Native start changed")
        accepted += 1
        try refuse(base + [flag, text]) // no attachment to carry it
        try refuse(base + Array(extra.prefix(4)) + [flag, text]) // incomplete attachment
        for malformed in ["AAAA", "!!!!", String(text.dropLast(8)), text + "AAAA", " " + text] {
            try refuse(base + extra + [flag, malformed])
        }
        try refuse(base + extra + [flag, text, flag, text])
        print("PASS worker attachment admission: \(accepted) accepted, \(rejected) rejected; no filesystem/model access")
    }
}
