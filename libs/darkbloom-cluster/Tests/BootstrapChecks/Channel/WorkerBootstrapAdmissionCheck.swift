import Darwin
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
        for value in [String(now), String(lifetime + 1), "0" + String(lifetime), "-1"] {
            try refuse(replacing(base + extra, "--bootstrap-deadline-uptime-nanoseconds", value))
        }
        for value in ["relative", "/" + String(repeating: "a", count: 103), "/bad\0path"] {
            try refuse(replacing(base + extra, "--bootstrap-socket-path", value))
        }
        print("PASS worker attachment admission: \(accepted) accepted, \(rejected) rejected; no filesystem/model access")
    }
}
