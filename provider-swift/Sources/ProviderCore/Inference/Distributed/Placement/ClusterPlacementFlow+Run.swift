import Darwin
import Foundation
import DarkbloomClusterPlacement
import DarkbloomClusterProcess
import DarkbloomClusterProtocol
import DarkbloomClusterRemote

extension ClusterPlacementFlow {
    /// The command that asks the other Mac for its profile: OpenSSH with the
    /// installed session's own pinned options (this member's identity file and
    /// pinned known-hosts file, no agent, no prompt), running that Mac's plan
    /// tool, which is installed beside its worker as this Mac's is.
    static func peerProfileCommand(local: ClusterPairDescription.Member,
                                   peer: ClusterPairDescription.Member) throws -> ClusterWorkerLaunch {
        // The SSH route is the developer harness's only: a pair reached over the
        // link has its profiles exchanged by the guided flow (`darkbloom cluster`).
        guard let trust = local.trust else {
            throw ClusterConfigurationError.invalid("This pair is reached over the link control channel: plan it with `darkbloom cluster`, which asks the other Mac over the paired link")
        }
        let route = try ClusterSSHConfiguration(host: peer.host, user: peer.user, port: peer.port,
            knownHostsFile: URL(fileURLWithPath: trust.knownHostsFile),
            identityFile: URL(fileURLWithPath: trust.identityFile), installedDarkbloom: peer.ownerExecutable)
        let tool = URL(fileURLWithPath: peer.workerExecutable).deletingLastPathComponent().appendingPathComponent(toolName)
        return try route.describeDevice(planTool: tool.path)
    }

    /// Asks the other Mac for its profile, now. A profile is an observation,
    /// not an authority: a Mac that overstates its memory gets a plan its own
    /// load gate then refuses.
    static func fetchPeerProfile(local: ClusterPairDescription.Member, peer: ClusterPairDescription.Member,
                                 deadline: UInt64) throws -> ClusterDeviceProfile {
        let command = try peerProfileCommand(local: local, peer: peer)
        let data: Data
        do {
            data = try DistributedCapabilityProbe.run(executable: command.executable, arguments: command.arguments,
                deadline: deadline, maximumOutputBytes: ClusterDeviceProfile.maximumEncodedBytes)
        } catch {
            throw ClusterConfigurationError.invalid("The other Mac (\(peer.id)) did not give its profile over the pinned SSH route. "
                + "Either this Mac's identity is not accepted there, its pinned host key differs, or \(toolName) is not installed beside "
                + "that Mac's worker. Run `\(toolName) device --json --index` on that Mac and pass the file with --peer-profile instead.")
        }
        do { return try ClusterDeviceProfile.decode(data) } catch {
            throw ClusterConfigurationError.invalid("The other Mac (\(peer.id)) answered over the pinned SSH route with something that is not a device profile; "
                + "its \(toolName) and this Mac's must be one build.")
        }
    }

    /// The whole step on this Mac. `deadline` bounds the child commands.
    public static func run(_ inputs: Inputs, deadline: UInt64) throws -> Outcome {
        let description = try ClusterPairDescription.decode(
            ClusterConfigurationFiles.read(inputs.pairDescription, maximum: ClusterPairDescription.maximumBytes))
        let capabilityData = try ClusterConfigurationFiles.read(inputs.capability, maximum: ClusterRuntimeCapabilityCodec.maximumBytes)
        guard ClusterConfigurationSyntax.hash(inputs.capabilitySHA256),
              ClusterConfigurationCodec.sha256(capabilityData) == inputs.capabilitySHA256,
              description.capabilitySHA256 == inputs.capabilitySHA256 else {
            throw ClusterConfigurationError.invalid("Capability input digest differs from the pin or from the pair description")
        }
        let capability = try ClusterCapabilityRecord.decode(capabilityData, writtenBy: "the worker (\(inputs.capability.path))")
        guard let local = description.members.first(where: { $0.id == inputs.localMemberID }) else {
            throw ClusterConfigurationError.invalid("This Mac's member ID, \(inputs.localMemberID), is not in the pair description")
        }
        // The plan tool is installed beside the worker it belongs to.
        let tool = URL(fileURLWithPath: local.workerExecutable).deletingLastPathComponent().appendingPathComponent(toolName)
        guard FileManager.default.isExecutableFile(atPath: tool.path) else {
            throw ClusterConfigurationError.invalid("\(toolName) is not installed beside this Mac's worker (\(tool.path)). "
                + "It is built and released with the worker; install the two together.")
        }
        // With its speed index: two Macs' indices relate their speeds when no speed was measured for the model.
        let localProfile = try ClusterDeviceProfile.decode(DistributedCapabilityProbe.run(executable: tool,
            arguments: ["device", "--json", "--index"], deadline: deadline, maximumOutputBytes: ClusterDeviceProfile.maximumEncodedBytes))
        let layout = try ClusterModelLayout.decode(DistributedCapabilityProbe.run(executable: tool,
            arguments: ["layout", "--model-dir", local.modelDirectory, "--json"]
                + ClusterMiMoPrivateImagePolicy.profileArguments(capability), deadline: deadline,
            maximumOutputBytes: ClusterModelLayout.maximumEncodedBytes))
        let peerProfile: ClusterDeviceProfile
        if let file = inputs.peerProfile {
            peerProfile = try ClusterDeviceProfile.decode(
                ClusterConfigurationFiles.read(file, maximum: ClusterDeviceProfile.maximumEncodedBytes))
        } else {
            guard let peer = description.members.first(where: { $0.id != inputs.localMemberID }) else {
                throw ClusterConfigurationError.invalid("The pair description names no other member")
            }
            peerProfile = try fetchPeerProfile(local: local, peer: peer, deadline: deadline)
        }
        let measurements = try inputs.speedMeasurements.map { url -> ClusterSpeedMeasurement in
            let value = try JSONDecoder().decode(ClusterSpeedMeasurement.self, from: ClusterConfigurationFiles.read(url, maximum: 65_536))
            try value.validate()
            return value
        }
        // The profiles this plan read are kept for the serving leader's per-request route,
        // and the speed records of requests this pair served join the measurements.
        let home = FileManager.default.homeDirectoryForCurrentUser
        if let peer = description.members.first(where: { $0.id != inputs.localMemberID }) {
            ClusterMemberProfiles.record([inputs.localMemberID: localProfile, peer.id: peerProfile], homeDirectory: home)
        }
        let decided = try decide(description: description, capability: capability, localMemberID: inputs.localMemberID,
            localProfile: localProfile, peerProfile: peerProfile, layout: layout, measurements: measurements,
            promptTokens: inputs.promptTokens, outputTokens: inputs.outputTokens, regime: inputs.regime,
            served: ClusterServedSpeedHistory.entries(homeDirectory: home),
            link: ClusterLinkProbeHistory.costs(homeDirectory: home, members: description.members.map(\.id)) ?? .unmeasured)
        var written: [URL] = []
        var lines = decided.lines
        if let setup = decided.setup {
            guard mkdir(inputs.output.path, 0o700) == 0 else {
                throw ClusterConfigurationError.invalid("Cannot create the output directory (it must not exist yet): \(inputs.output.path)")
            }
            var files = setup.configurations.map { (name: $0.key + ".setup.json", data: $0.value) }
            files.append(("plan.txt", Data((decided.lines.joined(separator: "\n") + "\n").utf8)))
            for file in files.sorted(by: { $0.name < $1.name }) {
                let url = inputs.output.appendingPathComponent(file.name)
                let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
                guard descriptor >= 0 else { throw ClusterConfigurationError.invalid("Cannot write \(file.name)") }
                defer { close(descriptor) }
                guard file.data.withUnsafeBytes({ write(descriptor, $0.baseAddress, $0.count) }) == file.data.count else {
                    throw ClusterConfigurationError.invalid("Cannot write \(file.name)")
                }
                written.append(url)
            }
            lines.append("  Wrote a setup for each Mac in \(inputs.output.path). On each Mac: "
                + "`darkbloom cluster configure --input <that Mac's setup> --capability <record> --capability-sha256 \(inputs.capabilitySHA256.prefix(12))…`.")
        }
        return .init(lines: lines, result: decided.result, setup: decided.setup, written: written)
    }
}
