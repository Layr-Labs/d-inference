import Darwin
import Foundation
import DarkbloomClusterRuntime
import DarkbloomClusterSecurity
import MLX
import MLXLLM

/// Metadata quotation only. Never installs a cap or loads a resident model.
enum GLM5NextCalibrationQuoteCommand {
    struct Options {
        let request: String, directory: URL, epoch: UUID, rank: Int, deadline: UInt64
        init(_ arguments: [String], now: UInt64) throws {
            guard arguments.count == 10 else { throw GLM5NextCalibrationQuoteWire.invalid("Expected five named options") }
            var fields: [String: String] = [:]
            for index in stride(from: 0, to: arguments.count, by: 2) {
                guard fields.updateValue(arguments[index + 1], forKey: arguments[index]) == nil else {
                    throw GLM5NextCalibrationQuoteWire.invalid("Repeated option")
                }
            }
            guard Set(fields.keys) == ["--request", "--model-dir", "--membership-epoch", "--rank", "--deadline-uptime-nanoseconds"],
                  let request = fields["--request"], let path = fields["--model-dir"],
                  let epoch = UUID(uuidString: fields["--membership-epoch"]!),
                  let rank = Int(fields["--rank"]!), (0...1).contains(rank),
                  let deadline = UInt64(fields["--deadline-uptime-nanoseconds"]!), deadline > now,
                  deadline - now <= 300_000_000_000 else { throw GLM5NextCalibrationQuoteWire.invalid("Invalid options/deadline") }
            for value in [request, path] {
                guard value.hasPrefix("/"), value.utf8.count <= 4096,
                      !value.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }),
                      !value.split(separator: "/", omittingEmptySubsequences: false).dropFirst().contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
                    throw GLM5NextCalibrationQuoteWire.invalid("Noncanonical path")
                }
            }
            self.request = request; directory = URL(fileURLWithPath: path)
            self.epoch = epoch; self.rank = rank; self.deadline = deadline
        }
    }
    struct Response: Encodable {
        let version = 1
        let purpose = "calibrationQuotation"
        let quoteRequestID: UUID
        let quoteRequestSHA256: String
        let rank: Int, cut: Int
        let repository: String, revision: String, artifactSHA256: String
        let rawConfigurationFileSHA256: String, normalizedConfigurationSHA256: String
        let descriptorSHA256: String, inventorySHA256: String, numericalPolicySHA256: String
        let executionEnvironmentSHA256: String
        let nativeBytes: Int, hostBytes: Int, loadCapacityBytes: Int, requestCapacityBytes: Int
        let qualifiesMaximumEnvelope = false
        let payloadVerified = false
        let binding: GLM5NextCalibration.Binding
    }
    static func run(arguments: [String]) throws {
        let options = try Options(arguments, now: DispatchTime.now().uptimeNanoseconds)
        signal(SIGPIPE, SIG_IGN)
        // Metadata may initialize Metal, but never owns tensor/model allocations.
        // A hard process deadline also bounds an unresponsive filesystem/driver.
        _ = try WorkerStartupDeadline.arm(uptimeNanoseconds: options.deadline, expire: { Darwin._exit(124) })
        let credential = try WorkerDataPlaneTrust.read(descriptor: STDIN_FILENO, until: options.deadline,
            epoch: options.epoch, rank: options.rank)
        let bytes = try WorkerCapabilityInput.read(options.request, maximumBytes: 256 << 10, deadline: options.deadline)
        let verified = try GLM5NextCalibrationQuoteWire.decode(bytes,
            memberPublicKey: credential.memberIdentity.identityPublicKey, peerPublicKey: credential.peerPin.identityPublicKey,
            epoch: options.epoch, rank: options.rank, now: Int64(Date().timeIntervalSince1970))
        let response = try quote(verified, options: options, reauthenticate: {
            try WorkerCapabilityInput.check(options.deadline)
            _ = try GLM5NextCalibrationQuoteWire.decode(bytes,
                memberPublicKey: credential.memberIdentity.identityPublicKey, peerPublicKey: credential.peerPin.identityPublicKey,
                epoch: options.epoch, rank: options.rank, now: Int64(Date().timeIntervalSince1970))
        })
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let output = try encoder.encode(response)
        guard output.count <= 65_536 else { throw GLM5NextCalibrationQuoteWire.invalid("Response exceeds bound") }
        try write(output + Data([10]), deadline: options.deadline)
    }

    static func quote(_ verified: GLM5NextCalibrationQuoteWire.Verified, options: Options,
                      reauthenticate: () throws -> Void) throws -> Response {
        try reauthenticate()
        let p = verified.request.selection
        guard p.epoch == options.epoch, p.rank == options.rank else {
            throw GLM5NextCalibrationQuoteWire.invalid("Quote options differ from authenticated request")
        }
        try GLM5NextCalibrationQuoteWire.requireEnvironment(ProcessInfo.processInfo.environment, request: verified.request)
        let now = Int64(Date().timeIntervalSince1970)
        let uptime = DispatchTime.now().uptimeNanoseconds
        guard now >= 0, p.expiresUnixSeconds > now,
              options.deadline > uptime,
              options.deadline - uptime <= UInt64(p.expiresUnixSeconds - now) * 1_000_000_000 else {
            throw GLM5NextCalibrationQuoteWire.invalid("Quotation outlives authorization")
        }
        let environment = try GLM5NextWorkerQualification.LiveEnvironment(expected: p.environment, deadline: options.deadline)
        let digest = try GLM5NextWorkerQualification.hash(p.environment)
        let config = try WorkerCapabilityInput.read(options.directory.appendingPathComponent("config.json").path,
            maximumBytes: 32 << 20, deadline: options.deadline)
        let descriptor = try GLM5NextResidentDescriptor(modelID: GLM5NextWorkerQualification.modelID,
            artifactIdentity: .init(repository: p.repository, revision: p.revision,
                files: p.files.mapValues { .init(bytes: $0.bytes, sha256: $0.sha256) }),
            artifactAggregateSHA256: p.artifactSHA256, configurationBytes: config, cut: p.cut,
            storage: .nvfp4Hybrid, executionPolicy: .serving, profileID: p.profileID,
            maximumPromptTokens: p.maximumPromptTokens, maximumChunkTokens: p.maximumChunkTokens,
            maximumOutputTokens: p.maximumOutputTokens, maximumContextTokens: p.maximumContextTokens)
        let inventory = try descriptor.inspectInventory(directory: options.directory)
        try GLM5NextCalibration.requirePinnedInventory(inventory)
        let binding = try GLM5NextCalibration.binding(descriptor: descriptor, inventory: inventory)
        let plan = try GLM5NextCalibration.plan(descriptor: descriptor, inventory: inventory, rank: p.rank,
            authorization: verified.request.authorization, authorizationSHA256: verified.requestSHA256,
            executionEnvironmentSHA256: digest, authenticate: reauthenticate, requireEnvironment: { actual in
                try WorkerCapabilityInput.check(options.deadline)
                guard actual == digest, Int64(Date().timeIntervalSince1970) < p.expiresUnixSeconds else {
                    throw GLM5NextCalibrationQuoteWire.invalid("Environment authorization expired")
                }
                try environment.check()
            }, maximumBufferBytes: GPU.deviceInfo().maxBufferSize,
            allocationBound: { try Memory.allocationFootprintUpperBound(byteCount: $0) },
            hostAllocationBound: { try GLM5NextWorkerQualification.hostBound($0,
                quantum: p.hostAllocationQuantum, overhead: p.hostAllocationOverhead) })
        try reauthenticate(); try environment.check()
        let q = plan.quote
        let bounds = try GLM5NextAutomaticPlacement.currentDeviceBounds(
            profile: ClusterDeviceProfileSampler.sample(), authorization: verified.request.authorization)
        try bounds.requireFits(nativeBytes: q.nativeBytes, hostBytes: q.hostBytes)
        return Response(quoteRequestID: verified.request.quoteRequestID, quoteRequestSHA256: verified.requestSHA256,
            rank: q.rank, cut: q.cut, repository: p.repository, revision: p.revision, artifactSHA256: p.artifactSHA256,
            rawConfigurationFileSHA256: p.files["config.json"]!.sha256, normalizedConfigurationSHA256: q.configurationSHA256,
            descriptorSHA256: q.descriptorSHA256, inventorySHA256: q.inventorySHA256,
            numericalPolicySHA256: q.numericalPolicySHA256, executionEnvironmentSHA256: q.executionEnvironmentSHA256,
            nativeBytes: q.nativeBytes, hostBytes: q.hostBytes, loadCapacityBytes: q.loadCapacityBytes,
            requestCapacityBytes: q.requestCapacityBytes, binding: binding)
    }
    private static func write(_ data: Data, deadline: UInt64) throws {
        let flags = fcntl(STDOUT_FILENO, F_GETFL)
        guard flags >= 0, fcntl(STDOUT_FILENO, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw GLM5NextCalibrationQuoteWire.invalid("Cannot bound stdout")
        }
        var offset = 0
        while offset < data.count {
            try WorkerCapabilityInput.check(deadline)
            let n = data.withUnsafeBytes { Darwin.write(STDOUT_FILENO, $0.baseAddress!.advanced(by: offset), $0.count - offset) }
            if n > 0 { offset += n }
            else if n < 0 && errno == EINTR { continue }
            else if n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                var fd = pollfd(fd: STDOUT_FILENO, events: Int16(POLLOUT), revents: 0)
                let result = poll(&fd, 1, 20)
                if result < 0 && errno != EINTR { throw GLM5NextCalibrationQuoteWire.invalid("Output poll failed") }
            } else { throw GLM5NextCalibrationQuoteWire.invalid("Output closed") }
        }
        try WorkerCapabilityInput.check(deadline)
    }
}
