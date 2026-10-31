import CryptoKit
import Darwin
import Foundation
import DarkbloomClusterBootstrap
import DarkbloomClusterProtocol
import DarkbloomClusterSecurity

/// TEST-ONLY executable, never an installed worker. Adapted from the actual
/// Tests/PreludeChecks native-then-mesh child. Real key establishment, actual
/// mesh rounds, credential/argv and process exit; synthetic finite report values.
/// No model LOAD, MLX, GPU, RDMA, qualification or serving READY.
@main enum CalibrationDispatchCPUChild {
    enum Failure: Error { case invalid }
    static func main() {
        do { try run() }
        catch { fputs("CPU calibration fixture refused\n", stderr); exit(71) }
    }
    static func arg(_ key: String) throws -> String {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: key), args.indices.contains(i + 1) else { throw Failure.invalid }
        return args[i + 1]
    }
    static func object(_ data: Data) throws -> [String: Any] {
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Failure.invalid }
        return value
    }
    static func integer(_ object: [String: Any], _ key: String) throws -> Int {
        guard let n = object[key] as? Int else { throw Failure.invalid }; return n
    }
    static func run() throws {
        // Fixture guard bounds even a broken parent, without changing supervisor
        // ownership: alarm is an actual child signal, never a pretend exit.
        signal(SIGALRM) { _ in _exit(99) }; alarm(20)
        guard CommandLine.arguments.contains("--glm-calibrate"),
              let rank = Int(try arg("--rank")), (0...1).contains(rank),
              let epoch = UUID(uuidString: try arg("--membership-epoch")),
              let ownerPID = Int32(try arg("--bootstrap-owner-pid")),
              let until = UInt64(try arg("--bootstrap-deadline-uptime-nanoseconds")),
              let startBytes = Data(base64Encoded: try arg("--native-authorization-start-base64")) else { throw Failure.invalid }
        let start = try ClusterNativeAuthorizationStart(encoded: startBytes)
        guard start.rank == rank, start.common.epoch == epoch else { throw Failure.invalid }
        var credential = Data()
        while credential.last != 10 && credential.count < 4096 {
            var byte: UInt8 = 0
            guard Darwin.read(STDIN_FILENO, &byte, 1) == 1 else { throw Failure.invalid }
            credential.append(byte)
        }
        let trust = try ClusterWorkerCodec.decodeDataPlaneTrust(credential)
        guard trust.rank == rank, trust.membershipEpoch == epoch else { throw Failure.invalid }
        credential.resetBytes(in: 0..<credential.count)
        let model = URL(fileURLWithPath: try arg("--model-dir"))
        try Data(startBytes).write(to: model.appendingPathComponent("dispatch-start-\(rank)"))
        let connection = try ClusterBootstrapConnection.connect(path: arg("--bootstrap-socket-path"),
            ownerProcessID: ownerPID, identity: .init(membershipEpoch: epoch, rank: rank),
            deadlineUptimeNanoseconds: until, mode: .nativeKeyPreludeV1)
        let context = try connection.beginNativeKeyPrelude(expecting: startBytes)
        let authority = try ClusterNativeRecordAuthority(ownedPrelude: context)
        let receipt = try authority.establish()
        guard receipt.rank == rank, receipt.transcriptSHA256.count == 32 else { throw Failure.invalid }
        let parts = [Data([2, 0, 0, 0]), Data(repeating: UInt8(rank + 1), count: 64),
                     Data([0, 0, 0, 0]), Data([0, 0, 0, 0])]
        for (sequence, bytes) in parts.enumerated() {
            let gathered = try connection.exchange(sequence: UInt64(sequence), contribution: bytes)
            guard gathered.count == 2 * bytes.count,
                  Data(gathered.dropFirst(rank * bytes.count).prefix(bytes.count)) == bytes else { throw Failure.invalid }
            if sequence == 1 {
                guard gathered == Data(repeating: 1, count: 64) + Data(repeating: 2, count: 64) else { throw Failure.invalid }
            }
        }
        try receipt.transcriptSHA256.write(to: model.appendingPathComponent("dispatch-bootstrap-\(rank)"))
        // Test watcher releases only after BOTH real owners report completed
        // bootstrap. This prevents child exit racing the last owner callback.
        let release = model.appendingPathComponent("dispatch-release-\(rank)")
        while !FileManager.default.fileExists(atPath: release.path) {
            guard DispatchTime.now().uptimeNanoseconds < until else { throw Failure.invalid }; usleep(1_000)
        }
        let envelope = try object(Data(contentsOf: URL(fileURLWithPath: arg("--glm-qualification"))))
        guard let encoded = envelope["payload"] as? String, let payload = Data(base64Encoded: encoded) else { throw Failure.invalid }
        let body = try object(payload)
        guard let p = body["selection"] as? [String: Any], let a = body["authorization"] as? [String: Any],
              let prompt = a["promptTokenIDs"] as? [Int], try integer(p, "rank") == rank else { throw Failure.invalid }
        let q = try object(Data(contentsOf: model.appendingPathComponent("dispatch-quote-\(rank).json")))
        let quote = Quote(authorizationSHA256: hash(payload), descriptorSHA256: try string(q, "descriptorSHA256"),
            cut: try integer(p, "cut"), rank: rank, nativeBytes: try integer(q, "nativeBytes"),
            hostBytes: try integer(q, "hostBytes"), loadCapacityBytes: try integer(p, "loadCapacityBytes"),
            requestCapacityBytes: try integer(p, "requestCapacityBytes"), inventorySHA256: try string(q, "inventorySHA256"),
            configurationSHA256: try string(q, "normalizedConfigurationSHA256"), numericalPolicySHA256: try string(q, "numericalPolicySHA256"),
            executionEnvironmentSHA256: try string(q, "executionEnvironmentSHA256"), qualifiesMaximumEnvelope: false)
        let output = try integer(a, "outputCount")
        let phases = ["before-load", "loaded"] + Array(repeating: "committed-token", count: rank == 0 ? output : 0) + ["request-finished"]
        let report = Report(nativeHardCapBytes: try integer(a, "nativeHardCapBytes"), hostBudgetBytes: try integer(a, "hostBudgetBytes"),
            osHeadroomBytes: try integer(a, "osHeadroomBytes"), quote: quote,
            observations: phases.map { Observation(phase: $0, nativeActiveBytes: 10, nativePeakBytes: 20,
                host: Host(mallocBytes: 10, processFootprintBytes: 20)) }, committedTokens: prompt.count + output - 1,
            qualifiesMaximumEnvelope: false, requiresProcessExit: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let line = try encoder.encode(report) + Data([10])
        guard line.count <= 65_536 else { throw Failure.invalid }
        // Explicit test-only scheduling control. No report/exit is supplied by
        // the fixture: this actual child stays alive until its hold is removed.
        let reportHold = model.appendingPathComponent("dispatch-report-hold-\(rank)")
        if FileManager.default.fileExists(atPath: reportHold.path) {
            try Data("held-before-report\n".utf8).write(
                to: model.appendingPathComponent("dispatch-report-held-\(rank)"))
            while FileManager.default.fileExists(atPath: reportHold.path) {
                guard DispatchTime.now().uptimeNanoseconds < until else { throw Failure.invalid }
                usleep(1_000)
            }
        }
        try FileHandle.standardOutput.write(contentsOf: line)
        withExtendedLifetime(authority) {}
    }
    static func hash(_ value: Data) -> String { SHA256.hash(data: value).map { String(format: "%02x", $0) }.joined() }
    static func string(_ object: [String: Any], _ key: String) throws -> String {
        guard let value = object[key] as? String else { throw Failure.invalid }; return value
    }
    struct Quote: Codable {
        let authorizationSHA256: String, descriptorSHA256: String
        let cut: Int, rank: Int, nativeBytes: Int, hostBytes: Int, loadCapacityBytes: Int, requestCapacityBytes: Int
        let inventorySHA256: String, configurationSHA256: String, numericalPolicySHA256: String, executionEnvironmentSHA256: String
        let qualifiesMaximumEnvelope: Bool
    }
    struct Host: Codable { let mallocBytes: Int, processFootprintBytes: Int }
    struct Observation: Codable { let phase: String; let nativeActiveBytes: Int, nativePeakBytes: Int; let host: Host }
    struct Report: Codable {
        let nativeHardCapBytes: Int, hostBudgetBytes: Int, osHeadroomBytes: Int
        let quote: Quote; let observations: [Observation]; let committedTokens: Int
        let qualifiesMaximumEnvelope: Bool, requiresProcessExit: Bool
    }
}
