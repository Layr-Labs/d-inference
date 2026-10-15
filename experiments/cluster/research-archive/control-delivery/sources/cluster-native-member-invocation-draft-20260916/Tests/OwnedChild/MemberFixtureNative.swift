import Darwin
import Foundation
import DarkbloomClusterBootstrap
import DarkbloomClusterProtocol
import DarkbloomClusterSecurity

private final class UnusedFixtureIO: ClusterRecordByteIO {
    let localRank: Int
    let maximumFrameBytes: Int
    let worldSize = 2
    init(rank: Int, frame: Int) { localRank = rank; maximumFrameBytes = frame }
    func sendCompleted(_ bytes: Data, check: () throws -> Void) throws { throw MemberFixtureError.invalid }
    func receiveCompleted(byteCount: Int, check: () throws -> Void) throws -> Data { throw MemberFixtureError.invalid }
}

func memberFixtureNative(executable: URL) throws {
    let configuration = try MemberFixtureConfiguration.read(beside: executable)
    let start = try configuration.start
    let args = Array(CommandLine.arguments.dropFirst(2))
    guard args.count == 8, Set(stride(from: 0, to: 8, by: 2).map { args[$0] }) ==
        Set(["--bootstrap-socket-path", "--bootstrap-owner-pid", "--bootstrap-deadline-uptime-nanoseconds", "--native-authorization-start-base64"]) else { throw MemberFixtureError.invalid }
    let values = Dictionary(uniqueKeysWithValues: stride(from: 0, to: 8, by: 2).map { (args[$0], args[$0 + 1]) })
    guard let path = values["--bootstrap-socket-path"], let owner = Int32(values["--bootstrap-owner-pid"]!),
          let deadline = UInt64(values["--bootstrap-deadline-uptime-nanoseconds"]!),
          values["--native-authorization-start-base64"] == configuration.startBase64 else { throw MemberFixtureError.invalid }
    // This marker records the actual native launch, not key or model readiness.
    let directory = executable.deletingLastPathComponent()
    try Data("\(getpid())\n".utf8).write(to: directory.appendingPathComponent("native-started"), options: .withoutOverwriting)
    if configuration.behavior == "forbidden-ready" {
        let ready = ClusterWorkerReady(identity: try configuration.identity(epoch: start.common.epoch), rank: start.rank,
            profile: MemberFixtureConfiguration.profile, executionPlanSHA256: start.common.planSHA256.hex, requestCapacityBytes: 4096)
        try FileHandle.standardOutput.write(contentsOf: ClusterWorkerCodec.encode(ClusterWorkerEventFrame(
            membershipEpoch: start.common.epoch, sequence: 0, requestID: nil, event: .ready(ready))))
        return
    }
    guard configuration.behavior == "key-only" else { throw MemberFixtureError.invalid }
    let connection = try ClusterBootstrapConnection.connect(path: path, ownerProcessID: owner,
        identity: .init(membershipEpoch: start.common.epoch, rank: start.rank),
        deadlineUptimeNanoseconds: deadline, mode: .nativeKeyPreludeV1)
    defer { connection.cancel() }
    let context = try connection.beginNativeKeyPrelude(expecting: start.canonicalBytes)
    let authority = try ClusterNativeRecordAuthority(ownedPrelude: context)
    defer { authority.invalidate() }
    let receipt = try authority.establish()
    let transport = try authority.makeRecordTransport(io: UnusedFixtureIO(rank: start.rank, frame: start.common.maximumTransportFrameBytes))
    guard transport.status.active else { throw MemberFixtureError.invalid }
    // Only public evidence is persisted. Private/shared keys never leave A.
    let report: [String: Any] = ["rank": start.rank, "pid": getpid(), "ownerPID": getppid(),
        "transcriptSHA256": receipt.transcriptSHA256.hex, "confirmed": true,
        "recordTransportConstructed": true, "modelReadyPublished": false]
    try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]).write(
        to: directory.appendingPathComponent("native-public.json"), options: .withoutOverwriting)
    let marker = Data("native-key-prelude-complete-v1".utf8)
    guard try connection.exchange(sequence: 0, contribution: marker) == marker + marker else { throw MemberFixtureError.invalid }
    authority.invalidate()
    guard !transport.status.active else { throw MemberFixtureError.invalid }
}
