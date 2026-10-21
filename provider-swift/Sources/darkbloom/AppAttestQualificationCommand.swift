import AppKit
import CryptoKit
import Darwin
import Foundation
import os
import ProviderAppAttest
import ProviderCore

/// An explicitly authorized physical diagnostic, not an alternate serving mode.
/// It never loads provider config, installed credentials, models or launch agents.
enum AppAttestQualificationCommand {
    static let argument = "--app-attest-qualification-v1"
    static let environmentKey = "DARKBLOOM_NATIVE_APP_ATTEST_QUALIFICATION"
    static let appKitEnvironmentKey = "DARKBLOOM_NATIVE_APPKIT_QUALIFICATION"

    enum Failure: String, Error {
        case optInRequired, invalidArguments, loopbackRequired, privateDirectoryRequired
        case invalidTestInput, workerNotReaped, unexpectedReply
        case incompleteQualification, executableUnavailable, mainThreadRequired
    }

    static func runIfRequested(_ arguments: [String]) async {
        guard arguments.first == argument else { return }
        do {
            await execute(try Inputs(arguments))
        } catch {
            fail(error)
        }
    }

    static func requestsAppKitHost(_ arguments: [String]) -> Bool {
        arguments.first == argument && ProcessInfo.processInfo.environment[appKitEnvironmentKey] == "1"
    }

    @MainActor private static var retainedDelegate: QualificationAppDelegate?

    @MainActor static func runHosted(_ arguments: [String]) -> Never {
        do {
            let inputs = try Inputs(arguments)
            guard Thread.isMainThread else { throw Failure.mainThreadRequired }
            let app = NSApplication.shared
            let delegate = QualificationAppDelegate(inputs: inputs)
            retainedDelegate = delegate
            app.delegate = delegate
            app.setActivationPolicy(.accessory)
            app.run()
            fail(Failure.incompleteQualification)
        } catch {
            fail(error)
        }
    }

    private struct Inputs: Sendable {
        let url: String
        let scope: String
        let token: String
        let binaryHash: String
        let scenario: String

        init(_ arguments: [String]) throws {
            guard ProcessInfo.processInfo.environment[AppAttestQualificationCommand.environmentKey] == "1",
                  AppAttestWorkerSelection.qualificationCandidateEnabled else { throw Failure.optInRequired }
            guard arguments.count == 4, arguments[0] == AppAttestQualificationCommand.argument,
                  ["worker-recovery", "callback-recovery"].contains(arguments[3]) else { throw Failure.invalidArguments }
            url = try AppAttestQualificationCommand.coordinatorURL(arguments[1])
            let directory = try PrivateInputs(path: arguments[2])
            token = try directory.hexadecimalFile("auth-token")
            let expectedHash = try directory.hexadecimalFile("binary-sha256")
            binaryHash = try SignedReleaseIdentity.verifyCurrent(expectedBinarySHA256: expectedHash,
                expectedVersion: ProviderCore.version).executableSHA256
            scope = "native-qualification:\(url):\(directory.path)"
            scenario = arguments[3]
        }
    }

    @MainActor private final class QualificationAppDelegate: NSObject, NSApplicationDelegate {
        let inputs: Inputs
        private var qualification: Task<Never, Never>?

        init(inputs: Inputs) {
            self.inputs = inputs
            super.init()
        }

        func applicationDidFinishLaunching(_: Notification) {
            // Unlike ProviderAppDelegate this host never registers APNs or
            // starts a provider lifecycle. Capture before any async suspension.
            let diagnostics = AppAttestWorkerRuntimeDiagnostics.capture()
            AppAttestQualificationCommand.record("appkit_did_finish_launching", fields: ["parent_pid": getpid(), "main_thread": Thread.isMainThread])
            let inputs = inputs
            qualification = Task { await AppAttestQualificationCommand.execute(inputs, parentDiagnostics: diagnostics) }
        }
    }

    private static func execute(_ inputs: Inputs, parentDiagnostics: AppAttestWorkerRuntimeDiagnostics? = nil) async -> Never {
        do {
            try await run(url: inputs.url, scope: inputs.scope, token: inputs.token,
                binaryHash: inputs.binaryHash, scenario: inputs.scenario, parentDiagnostics: parentDiagnostics)
            _exit(0)
        } catch {
            fail(error)
        }
    }

    private static func fail(_ error: Error) -> Never {
        let reason = (error as? Failure)?.rawValue
            ?? (error as? AppAttestWorkerError)?.rawValue
            ?? String(describing: error)
        record("qualification_failed", fields: ["reason": reason])
        _exit(78)
    }

    static func coordinatorURL(_ value: String) throws -> String {
        guard let parts = URLComponents(string: value), parts.scheme == "ws",
              parts.host == "127.0.0.1", let port = parts.port, (1024...65535).contains(port),
              parts.path == "/ws/provider", parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil,
              value == "ws://127.0.0.1:\(port)/ws/provider" else { throw Failure.loopbackRequired }
        return value
    }

    private static func run(url: String, scope: String, token: String, binaryHash: String, scenario: String,
                            parentDiagnostics: AppAttestWorkerRuntimeDiagnostics?) async throws {
        let encodedDiagnostics = try JSONEncoder().encode(parentDiagnostics ?? AppAttestWorkerRuntimeDiagnostics.capture())
        record("parent_runtime_diagnostics", fields: ["snapshot": try JSONSerialization.jsonObject(with: encodedDiagnostics)])
        let endpoint = NodeKeyPair.generate()
        let hardware = try HardwareDetector.detect()
        let os = ProcessInfo.processInfo.operatingSystemVersion
        var size = 128
        var build = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.osversion", &build, &size, nil, 0) == 0,
              let parent = ProcessIdentity.current() else { throw Failure.executableUnavailable }
        let status = AppAttestStatus(
            osVersion: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
            osBuild: String(decoding: build.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self), appVersion: ProviderCore.version,
            chip: hardware.chipName, binaryHash: binaryHash, machineModel: hardware.machineModel,
            memoryGB: String(hardware.memoryGb), cpuTotal: String(hardware.cpuCores.total),
            cpuPerformance: String(hardware.cpuCores.performance), cpuEfficiency: String(hardware.cpuCores.efficiency),
            gpuCores: String(hardware.gpuCores))
        let worker = try AppAttestWorkerClient(scope: scope, endpointPublicKey: endpoint.publicKeyBase64) { request in
            let clear = try endpoint.decryptPayload(EncryptedPayload(
                ephemeralPublicKey: request.encryptedChallenge.ephemeralPublicKey,
                ciphertext: request.encryptedChallenge.ciphertext))
            guard let value = String(data: clear, encoding: .utf8) else { throw Failure.unexpectedReply }
            return value
        }
        let client = CoordinatorClient(config: CoordinatorClientConfig(
            url: url, hardware: hardware, models: [], backendName: "mlx-swift", heartbeatInterval: 5,
            publicKey: endpoint.publicKeyBase64, authToken: token,
            privacyCapabilities: PrivacyCapabilities(textBackendInprocess: false, textProxyDisabled: true,
                sipEnabled: false, antiDebugEnabled: false, coreDumpsDisabled: false, envScrubbed: false),
            privateOnly: true), stats: AtomicProviderStats(), state: ProviderState(), liveAPNsToken: { nil },
            appAttestResumeResponder: { challenge, nonce in
                let response = try endpoint.appAttestResumeResponse(to: challenge, clientNonce: nonce)
                record("transport_resumption_answered")
                return response
            })
        // The physical harness can terminate only this diagnostic process. It
        // does not install or modify any persistent signal/launch configuration.
        signal(SIGTERM, SIG_IGN)
        let termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
        termination.setEventHandler { Task { await client.shutdown(); try? await worker.stop() } }
        termination.resume()
        defer { termination.cancel() }
        let deadline = Task {
            do { try await taskSleep(.seconds(420)) } catch { return }
            await client.shutdown()
            try? await worker.stop()
        }
        defer { deadline.cancel() }
        record("qualification_started", fields: ["parent_pid": parent.pid, "binary_sha256": binaryHash,
            "endpoint_sha256": SHA256.hash(data: endpoint.publicKeyBytes).map { String(format: "%02x", $0) }.joined(),
            "scenario": scenario, "engine_loaded": false])
        let (events, _) = await client.start()
        var assertions = 0
        var successfulAssertions = 0
        var recoveries = 0
        var complete = false
        let assertionEvents = OSAllocatedUnfairLock(initialState: [AppAttestWorkerClient.QualificationAssertionEvent]())
        do {
            eventLoop: for await event in events {
                switch event {
                case .connected:
                    record("transport_connected")
                case .disconnected:
                    record("transport_disconnected")
                    try await worker.cancelExchange()
                case .appAttestShadow(let request, let delivery):
                    if request.action == "assert" { assertions += 1 }
                    let suspend = scenario == "worker-recovery" && request.action == "assert" && assertions == 2
                    let discardCallback = scenario == "callback-recovery" && request.action == "assert" && assertions == 2
                    if discardCallback {
                        try await worker.armNextAssertionCallbackDiscardForQualification { event in
                            record("assertion_" + event.phase.rawValue, fields: ["parent_pid": parent.pid,
                                "worker_pid": event.processID, "worker_generation": event.workerGeneration.uuidString,
                                "sequence": event.sequence])
                            assertionEvents.withLock { $0.append(event) }
                        }
                    }
                    let stopped = suspend ? try await worker.suspendOwnedWorkerForQualification() : nil
                    if let stopped {
                        record("worker_stopped", fields: ["worker_pid": stopped.processID, "parent_pid": parent.pid,
                            "worker_generation": stopped.workerGeneration.uuidString])
                    }
                    let started = ContinuousClock.now
                    do {
                        let reply = try await worker.respond(to: request, status: status)
                        if let diagnostics = reply.runtimeDiagnostics {
                            let encoded = try JSONEncoder().encode(diagnostics)
                            record("worker_runtime_diagnostics", fields: ["snapshot": try JSONSerialization.jsonObject(with: encoded)])
                        }
                        guard !suspend else { throw Failure.unexpectedReply }
                        if discardCallback {
                            guard reply.payload.action == "assertion", reply.payload.result == "operation_timeout",
                                  reply.payload.proof == nil, reply.payload.appleError == nil else { throw Failure.unexpectedReply }
                            try await worker.cancelExchange()
                            let elapsed = started.duration(to: .now)
                            guard elapsed >= .seconds(25), elapsed < .seconds(35), parent.isCurrent() else { throw Failure.workerNotReaped }
                            let observationDeadline = ContinuousClock.now + .seconds(5)
                            var observations = assertionEvents.withLock { $0 }
                            while observations.count < 2, ContinuousClock.now < observationDeadline {
                                try await taskSleep(.milliseconds(10))
                                observations = assertionEvents.withLock { $0 }
                            }
                            guard observations.count == 2, observations[0].phase == .submitted,
                                  observations[1].phase == .callbackDiscarded,
                                  observations[0].processID == observations[1].processID,
                                  observations[0].workerGeneration == observations[1].workerGeneration,
                                  observations[0].sequence == observations[1].sequence else { throw Failure.incompleteQualification }
                            recoveries += 1
                            record("worker_reaped", fields: ["worker_pid": observations[0].processID, "parent_pid": parent.pid,
                                "worker_generation": observations[0].workerGeneration.uuidString,
                                "sequence": observations[0].sequence, "fault": "callback_discard",
                                "elapsed_seconds": Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18])
                        }
                        if reply.payload.action == "assertion", reply.payload.result == "ok" { successfulAssertions += 1 }
                        record("worker_reply", fields: ["action": reply.payload.action, "result": reply.payload.result ?? "missing"])
                        await delivery.send(reply.payload)
                    } catch {
                        guard suspend, error as? AppAttestWorkerError == .deadlineExceeded,
                              let stopped, parent.isCurrent() else { throw error }
                        let elapsed = started.duration(to: .now)
                        guard elapsed >= .seconds(80), elapsed < .seconds(89) else { throw Failure.workerNotReaped }
                        recoveries += 1
                        record("worker_reaped", fields: ["worker_pid": stopped.processID, "parent_pid": parent.pid,
                            "elapsed_seconds": Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18])
                        var reply = AppAttestShadowPayload(action: "assertion", session: request.session)
                        reply.protocolVersion = 3
                        reply.result = "operation_timeout"
                        reply.keyID = request.keyID
                        await delivery.send(reply)
                    }
                case .trustStatus(_, let value, let reason, _):
                    if value == "native_qualification_complete" {
                        guard parent.isCurrent(), successfulAssertions > 0,
                              scenario != "worker-recovery" || (recoveries == 1 && successfulAssertions == 2 && reason == "worker_recovery_verified"),
                              scenario != "callback-recovery" || (recoveries == 1 && successfulAssertions == 2 && reason == "callback_recovery_verified") else {
                            throw Failure.incompleteQualification
                        }
                        complete = true
                        break eventLoop
                    }
                default:
                    break
                }
            }
            try await worker.stop()
            await client.shutdown()
            guard complete else { throw Failure.incompleteQualification }
            record("qualification_complete", fields: ["parent_pid": parent.pid, "successful_assertions": successfulAssertions,
                "worker_recoveries": recoveries, "engine_loaded": false,
                "endpoint_sha256": SHA256.hash(data: endpoint.publicKeyBytes).map { String(format: "%02x", $0) }.joined()])
        } catch {
            try? await worker.stop()
            await client.shutdown()
            throw error
        }
    }

    private static func record(_ event: String, fields: [String: Any] = [:]) {
        var value = fields
        value["event"] = event
        if let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) {
            FileHandle.standardOutput.write(data + Data([10]))
        }
    }

    private final class PrivateInputs {
        let path: String
        private let descriptor: Int32

        init(path: String) throws {
            guard path.hasPrefix("/"), URL(fileURLWithPath: path).resolvingSymlinksInPath().path == path else { throw Failure.privateDirectoryRequired }
            let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw Failure.privateDirectoryRequired }
            var metadata = stat()
            guard fstat(fd, &metadata) == 0, metadata.st_uid == geteuid(), metadata.st_mode & 0o077 == 0 else {
                close(fd)
                throw Failure.privateDirectoryRequired
            }
            self.path = path
            descriptor = fd
        }

        deinit { close(descriptor) }

        func hexadecimalFile(_ name: String) throws -> String {
            let fd = openat(descriptor, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw Failure.invalidTestInput }
            defer { close(fd) }
            var metadata = stat()
            guard fstat(fd, &metadata) == 0, metadata.st_uid == geteuid(), metadata.st_mode & S_IFMT == S_IFREG,
                  metadata.st_mode & 0o077 == 0, metadata.st_nlink == 1, metadata.st_size == 64 else { throw Failure.invalidTestInput }
            var bytes = [UInt8](repeating: 0, count: 64)
            guard Darwin.read(fd, &bytes, bytes.count) == 64,
                  bytes.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw Failure.invalidTestInput }
            return String(decoding: bytes, as: UTF8.self)
        }
    }
}
