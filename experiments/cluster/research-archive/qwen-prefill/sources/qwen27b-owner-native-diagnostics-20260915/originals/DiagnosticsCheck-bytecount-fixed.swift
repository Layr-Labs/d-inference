import Foundation
import Darwin
import DarkbloomClusterProtocol
import DarkbloomClusterProcess

enum CheckFailure: Error { case failed(String) }
func check(_ value: Bool, _ label: String) throws {
    if !value { throw CheckFailure.failed(label) }
}
func decoded(_ data: Data?) throws -> [String: Any] {
    guard let data, let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw CheckFailure.failed("diagnostic JSON")
    }
    try check(data.count <= 8192 && data.last == 10 && !data.dropLast().contains(10), "record bound")
    return value
}

@main struct DiagnosticsCheck {
    static func main() throws {
        alarm(15)
        defer { alarm(0) }
        var groups = 0
        let empty = try decoded(OwnerNativeDiagnostics().encodedObservation())
        try check(empty["childConstructed"] as? Bool == false && empty["nativeCleanupObserved"] as? Bool == false
            && empty["termination"] is NSNull, "no fabricated child/cleanup")
        groups += 1
        let oversized = Data(repeating: 65, count: 20_000)
        let limited = try decoded(OwnerNativeDiagnostics.encode(constructed: true, rank: 1, pid: 123,
            terminal: .exited(7), cleanupObserved: true, diagnosticTail: oversized))
        let tail = Data(base64Encoded: limited["diagnosticTailBase64"] as! String)
        try check(tail == Data(oversized.suffix(4096)) && limited["diagnosticTailTruncated"] as? Bool == true,
                  "4096-byte diagnostic tail")
        let termination = limited["termination"] as? [String: Any]
        try check(termination?["kind"] as? String == "exited" && termination?["status"] as? Int == 7, "actual exit encoding")
        groups += 1
        for terminal in [ClusterWorkerProcessTermination.launchFailed, .signalled(15)] {
            let value = try decoded(OwnerNativeDiagnostics.encode(constructed: true, rank: 0, pid: nil,
                terminal: terminal, cleanupObserved: true, diagnosticTail: Data()))
            try check(value["termination"] is [String: Any], "terminal cases")
        }
        groups += 1
        let identity = ClusterWorkerIdentity(membershipEpoch: UUID(), modelID: "fixture",
            artifactSHA256: String(repeating: "a", count: 64), configurationSHA256: String(repeating: "b", count: 64),
            peers: [.init(id: "rank0", buildSHA256: String(repeating: "c", count: 64)),
                    .init(id: "rank1", buildSHA256: String(repeating: "d", count: 64))])
        let profile = ClusterWorkerProfile(id: "fixture", vocabularySize: 16, maximumPromptTokens: 8,
            maximumOutputTokens: 2, maximumChunkTokens: 4, maximumContextTokens: 16)
        let now = DispatchTime.now().uptimeNanoseconds
        let child = try ClusterWorkerProcess(launch: .init(executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf 'fabricated-native-failure\\n' >&2; exit 7"], environment: ["PATH": "/usr/bin:/bin"]),
            expectedIdentity: identity, rank: 1, profile: profile,
            executionPlanSHA256: String(repeating: "e", count: 64),
            startupDeadline: now + 2_000_000_000, lifetimeDeadline: now + 5_000_000_000)
        let holder = OwnerNativeDiagnostics(); holder.remember(child)
        let unlaunched = try decoded(holder.encodedObservation())
        try check(unlaunched["childConstructed"] as? Bool == true && unlaunched["termination"] is NSNull,
                  "construction is not termination")
        try child.launch(); child.waitForNativeCleanup()
        let actual = try decoded(holder.encodedObservation())
        try check(child.termination == .exited(7) && child.nativeCleanupObserved, "actual fake child exit")
        try check(actual["nativeCleanupObserved"] as? Bool == true
            && Data(base64Encoded: actual["diagnosticTailBase64"] as! String) == Data("fabricated-native-failure\n".utf8),
            "captured real Process stderr and cleanup")
        groups += 1
        var fds: [Int32] = [0, 0]
        try check(Darwin.pipe(&fds) == 0, "pipe")
        defer { Darwin.close(fds[0]); Darwin.close(fds[1]) }
        let beforeFlags = fcntl(fds[1], F_GETFL)
        try check(OwnerNativeDiagnostics.writeBounded(Data("bounded\n".utf8), descriptor: fds[1]), "normal write")
        let expected = Array("bounded\n".utf8)
        var bytes = [UInt8](repeating: 0, count: expected.count)
        try check(Darwin.read(fds[0], &bytes, bytes.count) == expected.count && bytes == expected, "normal bytes")
        try check(fcntl(fds[1], F_GETFL) == beforeFlags, "flags restored")
        groups += 1
        _ = fcntl(fds[1], F_SETFL, beforeFlags | O_NONBLOCK)
        let fill = [UInt8](repeating: 0, count: 4096)
        while Darwin.write(fds[1], fill, fill.count) > 0 {}
        _ = fcntl(fds[1], F_SETFL, beforeFlags)
        let began = DispatchTime.now().uptimeNanoseconds
        try check(!OwnerNativeDiagnostics.writeBounded(Data([1]), descriptor: fds[1]), "blocked output returns")
        try check(DispatchTime.now().uptimeNanoseconds - began < 2_000_000_000, "blocked output bounded")
        try check(fcntl(fds[1], F_GETFL) == beforeFlags, "blocked flags restored")
        groups += 1
        var closed: [Int32] = [0, 0]
        try check(Darwin.pipe(&closed) == 0, "closed pipe")
        Darwin.close(closed[0]); defer { Darwin.close(closed[1]) }
        try check(!OwnerNativeDiagnostics.writeBounded(Data([1]), descriptor: closed[1]), "closed reader no SIGPIPE")
        groups += 1
        print("{\"groups\":\(groups),\"actualFabricatedChildren\":1,\"modelOrNetworkExecuted\":false}")
    }
}
