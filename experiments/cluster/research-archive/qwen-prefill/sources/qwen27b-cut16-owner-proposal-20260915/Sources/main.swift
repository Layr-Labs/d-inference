import Foundation
import Darwin
import DarkbloomClusterProtocol
import DarkbloomClusterProcess
import DarkbloomClusterRemote

// Private qualification executable. Installed SSH command remains fixed; its
// trusted local owner.json supplies paths/identity, never an outer wire frame.
struct OwnerSettings: Decodable {
    let schema: String
    let clusterID: String
    let workerExecutable: String
    let modelDirectory: String
    let leaseDirectory: String
    let stageCut: Int
    let maximumLifetimeSeconds: Int
    let workerEnvironment: [String: String]
    let readyTemplateBase64: String
}
func settings(_ path: String) throws -> OwnerSettings {
    let fd = Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
    guard fd >= 0 else { throw ClusterOwnerStateError.invalid("Cannot open configured owner settings") }
    defer { Darwin.close(fd) }
    var before = stat(), after = stat()
    guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG, before.st_uid == geteuid(),
          before.st_mode & 0o022 == 0, before.st_size > 0, before.st_size <= 16_384 else {
        throw ClusterOwnerStateError.invalid("Unsafe or oversized owner settings")
    }
    var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
    while true {
        let n = Darwin.read(fd, &buffer, buffer.count)
        if n < 0 && errno == EINTR { continue }
        guard n >= 0, data.count + max(0, n) <= 16_384 else { throw ClusterOwnerStateError.invalid("Owner settings read failed") }
        if n == 0 { break }; data.append(contentsOf: buffer.prefix(n))
    }
    guard fstat(fd, &after) == 0, before.st_dev == after.st_dev, before.st_ino == after.st_ino,
          before.st_size == after.st_size, before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
          before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec, before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
          before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else { throw ClusterOwnerStateError.invalid("Owner settings changed") }
    if data.last != 10 { data.append(10) }
    try validateClusterWorkerEnvelope(data, commandStream: true)
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], Set(object.keys) ==
        Set(["schema", "clusterID", "workerExecutable", "modelDirectory", "leaseDirectory", "stageCut",
             "maximumLifetimeSeconds", "workerEnvironment", "readyTemplateBase64"]) else { throw ClusterOwnerStateError.invalid("Owner settings fields differ") }
    let value = try JSONDecoder().decode(OwnerSettings.self, from: data)
    guard value.schema == "darkbloom_configured_worker_owner_v1", (1...300).contains(value.maximumLifetimeSeconds),
          value.stageCut == Qwen27BQualificationScope.stageCut, value.workerExecutable.hasPrefix("/"), value.modelDirectory.hasPrefix("/"),
          value.leaseDirectory.hasPrefix("/") else { throw ClusterOwnerStateError.invalid("Owner configuration outside current worker scope") }
    return value
}
let args = Array(CommandLine.arguments.dropFirst())
guard args == ["cluster", "worker-owner", "--stdio"] else { throw ClusterOwnerStateError.invalid("Expected fixed cluster worker-owner --stdio command") }
let path = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("owner.json").path
let config = try settings(path)
guard let template = Data(base64Encoded: config.readyTemplateBase64),
      case .ready(let ready) = try ClusterWorkerCodec.decodeEvent(template).event,
      ready.identity.membershipEpoch == UUID(uuidString: "00000000-0000-0000-0000-000000000000") else {
    throw ClusterOwnerStateError.invalid("Expected native ready template with zero placeholder epoch")
}
try Qwen27BQualificationScope.validate(ready)
let nativeDiagnostics = OwnerNativeDiagnostics()
defer { nativeDiagnostics.publish() }
try ClusterWorkerOwnerService.serveConfigured(input: STDIN_FILENO, output: STDOUT_FILENO,
    clusterID: config.clusterID, leaseDirectory: URL(fileURLWithPath: config.leaseDirectory),
    maximumLifetimeNanoseconds: UInt64(config.maximumLifetimeSeconds) * 1_000_000_000,
    bootstrapProfile: .mesh2, binding: { epoch, lease, incarnation in
        let identity = ClusterWorkerIdentity(membershipEpoch: epoch, modelID: ready.identity.modelID,
            artifactSHA256: ready.identity.artifactSHA256, configurationSHA256: ready.identity.configurationSHA256,
            peers: ready.identity.peers)
        return try .init(clusterID: config.clusterID, ownerIncarnation: incarnation, leaseID: lease,
            identity: identity, profile: ready.profile, rank: ready.rank, executionPlanSHA256: ready.executionPlanSHA256)
    }, native: { binding, deadline, attachment in
        guard let attachment else { throw ClusterOwnerStateError.invalid("Authenticated physical bootstrap is required") }
        let identity = binding.identity
        var arguments = ["--model-dir", config.modelDirectory, "--rank", String(binding.rank), "--stage-cut", String(config.stageCut),
            "--membership-epoch", identity.membershipEpoch.uuidString.lowercased(), "--model-id", identity.modelID,
            "--artifact-sha256", identity.artifactSHA256, "--configuration-sha256", identity.configurationSHA256,
            "--peer0-id", identity.peers[0].id, "--peer0-build-sha256", identity.peers[0].buildSHA256,
            "--peer1-id", identity.peers[1].id, "--peer1-build-sha256", identity.peers[1].buildSHA256,
            "--deadline-uptime-nanoseconds", String(deadline)]
        arguments += attachment.workerArguments
        let child = try ClusterWorkerProcess(launch: .init(executable: URL(fileURLWithPath: config.workerExecutable), arguments: arguments,
            environment: config.workerEnvironment), expectedIdentity: identity, rank: binding.rank, profile: binding.profile,
            executionPlanSHA256: binding.executionPlanSHA256,
            startupDeadline: min(deadline, DispatchTime.now().uptimeNanoseconds + 90_000_000_000), lifetimeDeadline: deadline)
        nativeDiagnostics.remember(child)
        return child
    })
