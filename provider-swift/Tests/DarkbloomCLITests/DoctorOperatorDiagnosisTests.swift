import Foundation
import ProviderCore
import Testing

@testable import darkbloom

/// `DoctorRunner.buildOperatorDiagnosis` reads the daemon state file, the
/// model cache and the coordinator release endpoint. Each case runs in its
/// own child process with a temporary provider home (`CLICommandSandbox`)
/// and a stub coordinator, so the diagnosis depends only on the inputs set
/// here.
///
/// Every case keeps the GPU capability probe out of the run: the probe runs
/// only when hardware is known and no fresh daemon state reports the
/// advertised models.
@Suite("Doctor operator diagnosis")
struct DoctorOperatorDiagnosisTests {

    @Test("a fresh daemon with App Attest authorization reports serving, model fit, runtime and billing")
    func freshAuthorizedDaemon() async {
        await #expect(processExitsWith: .success) {
            let sandbox = try CLICommandSandbox.enter()
            defer { sandbox.remove() }
            try sandbox.makeModel("acme/Cold-4bit")
            try sandbox.makeModel("acme/Warm-4bit")
            ModelScanner.configureCacheDirectory(sandbox.cache.path)
            CoordinatorStub.install([
                "/v1/releases/latest": .init(
                    status: 200, body: CLICommandSandbox.releaseJSON(version: "99.0.0")),
            ])
            let now = Date().timeIntervalSince1970
            sandbox.writeState(try CLICommandSandbox.runningState(
                now: now,
                trust: .init(
                    trustLevel: "hardware", status: "online", reason: "verified", receivedAt: now,
                    authorization: CLICommandSandbox.appAttestAuthorization(now: now)),
                attestationPublicKey: "attestation-key",
                currentModel: "acme/Warm-4bit",
                warmModels: ["acme/Warm-4bit"],
                advertisedModels: ["acme/Cold-4bit", "acme/Warm-4bit"],
                stats: .init(requestsServed: 7, tokensGenerated: 900, usageGaps: 0),
                capacity: .init(
                    totalMemoryGb: 128, gpuMemoryActiveGb: 4, loadUsableGb: 100,
                    loadHeadroomGb: 2, freeForLoadGb: 90),
                lastModelLoadError: .init(model: "acme/Cold-4bit", message: "weights unreadable", at: now - 30)))

            let diagnosis = await DoctorRunner.buildOperatorDiagnosis(
                snapshot: try sandbox.snapshot(hardware: CLICommandSandbox.hardware),
                coordinatorURL: CLICommandSandbox.coordinatorURL)

            let key = try #require(diagnosis.first { $0.name == "active se key" })
            #expect(key.section == .attestationKey)

            let authorization = try #require(diagnosis.first { $0.name == "serving authorization" })
            #expect(authorization.section == .trust)
            #expect(authorization.level == .pass)
            #expect(authorization.message.hasPrefix("App Attest authorizes this connection."))
            // An authorized connection skips the console-session readiness
            // checks and the MDM enrollment hint.
            #expect(!diagnosis.contains { $0.section == .attestationReadiness })
            #expect(!diagnosis.contains { ["mdm enrollment", "mdm verification", "App Attest setup"].contains($0.name) })

            let concurrency = try #require(diagnosis.first { $0.name == "serving concurrency" })
            #expect(concurrency.section == .traffic)
            #expect(concurrency.level == .info)

            // Only the cold advertised model is a load target; the warm one is resident.
            let fits = diagnosis.filter { $0.name == "model fits in RAM" }
            #expect(fits.count == 1)
            #expect(fits.first?.level == .pass)
            #expect(fits.first?.message.hasPrefix("acme/Cold-4bit needs ~") == true)

            let runtime = try #require(diagnosis.first { $0.name == "daemon connected" })
            #expect(runtime.level == .pass)
            #expect(runtime.message.hasPrefix("up 1h"))
            #expect(runtime.message.contains("acme/Warm-4bit"))
            #expect(runtime.message.hasSuffix("7 requests served."))

            let load = try #require(diagnosis.first { $0.name == "recent model load" })
            #expect(load.level == .warn)
            #expect(load.message == "FAILED for acme/Cold-4bit: weights unreadable")

            let billing = try #require(diagnosis.first { $0.name == "usage reporting" })
            #expect(billing.section == .billing)
            #expect(billing.level == .pass)
            #expect(billing.message == "7 requests / 900 tokens reported this session.")

            let version = try #require(diagnosis.first { $0.section == .version })
            #expect(version.level == .warn)
            #expect(version.message == "running \(ProviderCore.version); latest is 99.0.0.")
            #expect(CoordinatorStub.requests.contains { $0.url?.path == "/v1/releases/latest" })
        }
    }

    @Test("a fresh self-signed daemon explains its trust level and an up-to-date version")
    func freshSelfSignedDaemon() async {
        await #expect(processExitsWith: .success) {
            let sandbox = try CLICommandSandbox.enter()
            defer { sandbox.remove() }
            try sandbox.makeModel("acme/Only-4bit")
            ModelScanner.configureCacheDirectory(sandbox.cache.path)
            CoordinatorStub.install([
                "/v1/releases/latest": .init(
                    status: 200, body: CLICommandSandbox.releaseJSON(version: ProviderCore.version)),
            ])
            let now = Date().timeIntervalSince1970
            sandbox.writeState(try CLICommandSandbox.runningState(
                now: now,
                trust: .init(trustLevel: "self_signed", status: "online", reason: "awaiting mdm", receivedAt: now),
                advertisedModels: ["acme/Only-4bit"],
                stats: .init(requestsServed: 2, tokensGenerated: 40, usageGaps: 0),
                capacity: .init(
                    totalMemoryGb: 128, gpuMemoryActiveGb: 0, loadUsableGb: 0.5, loadHeadroomGb: 2,
                    freeForLoadGb: 0, loadTransitionActive: true)))

            let diagnosis = await DoctorRunner.buildOperatorDiagnosis(
                snapshot: try sandbox.snapshot(hardware: CLICommandSandbox.hardware),
                coordinatorURL: CLICommandSandbox.coordinatorURL)

            let trust = try #require(diagnosis.first { $0.name == "trust level" })
            #expect(trust.section == .trust)
            #expect(trust.level == .warn)
            #expect(trust.message.hasPrefix("self_signed / online — "))
            // Without App Attest authorization the readiness checks run.
            #expect(diagnosis.contains { $0.section == .attestationReadiness })
            #expect(!diagnosis.contains { $0.name == "serving authorization" })

            // The load budget is too small, but a model load is in progress,
            // so the verdict waits for an idle Mac instead of failing.
            let fit = try #require(diagnosis.first { $0.name == "model fits in RAM" })
            #expect(fit.level == .info)
            #expect(fit.message.contains("a request, model load, or reload is active"))

            #expect(diagnosis.first { $0.name == "daemon connected" }?.level == .pass)
            #expect(!diagnosis.contains { $0.name == "recent model load" })
            #expect(diagnosis.first { $0.name == "usage reporting" }?.message
                == "2 requests / 40 tokens reported this session.")

            let version = try #require(diagnosis.first { $0.section == .version })
            #expect(version.level == .pass)
            #expect(version.message == "running \(ProviderCore.version).")
        }
    }

    @Test("a stale running daemon reports a possible wedge and under-counted usage")
    func staleRunningDaemon() async {
        await #expect(processExitsWith: .success) {
            let sandbox = try CLICommandSandbox.enter()
            defer { sandbox.remove() }
            CoordinatorStub.install([
                "/v1/releases/latest": .json(503, #"{"error":"maintenance"}"#),
            ])
            let now = Date().timeIntervalSince1970
            sandbox.writeState(try CLICommandSandbox.runningState(
                now: now,
                writtenAt: now - 600,
                trust: .init(trustLevel: "hardware", status: "online", reason: "verified", receivedAt: now - 600),
                stats: .init(requestsServed: 10, tokensGenerated: 100, usageGaps: 3)))

            let diagnosis = await DoctorRunner.buildOperatorDiagnosis(
                snapshot: try sandbox.snapshot(hardware: nil),
                coordinatorURL: CLICommandSandbox.coordinatorURL)

            let key = try #require(diagnosis.first { $0.name == "active se key" })
            #expect(key.level == .warn)

            let trust = try #require(diagnosis.first { $0.name == "trust level" })
            #expect(trust.level == .warn)
            #expect(trust.message.hasPrefix("the daemon is running but hasn't received a trust status"))
            #expect(trust.fix?.contains("re-run `darkbloom doctor`") == true)

            let daemon = try #require(diagnosis.first { $0.name == "daemon" })
            #expect(daemon.section == .runtime)
            #expect(daemon.level == .warn)
            #expect(daemon.message.hasPrefix("running but its last update was "))
            #expect(daemon.message.hasSuffix("s ago — it may be wedged."))
            #expect(daemon.fix == "check `darkbloom logs`; consider `darkbloom stop && darkbloom start`.")

            let billing = try #require(diagnosis.first { $0.name == "usage reporting" })
            #expect(billing.level == .warn)
            #expect(billing.message
                == "3 completed request(s) had a missing/zero usage chunk (under-counting risk).")
            #expect(billing.fix?.contains("darkbloom report --dry-run") == true)

            // No hardware: only the concurrency line in the traffic section.
            #expect(diagnosis.filter { $0.section == .traffic }.map(\.name) == ["serving concurrency"])
            // A failed release check adds no version line.
            #expect(!diagnosis.contains { $0.section == .version })
        }
    }

    @Test("with no daemon the diagnosis says how to start one and skips live sections")
    func noDaemon() async {
        await #expect(processExitsWith: .success) {
            let sandbox = try CLICommandSandbox.enter()
            defer { sandbox.remove() }
            CoordinatorStub.install([
                "/v1/releases/latest": .init(
                    status: 200, body: CLICommandSandbox.releaseJSON(version: "99.0.0")),
            ])

            let diagnosis = await DoctorRunner.buildOperatorDiagnosis(
                snapshot: try sandbox.snapshot(hardware: nil),
                coordinatorURL: CLICommandSandbox.coordinatorURL)

            #expect(diagnosis.first?.name == "active se key")
            #expect(diagnosis.first?.level == .warn)
            let trust = try #require(diagnosis.first { $0.name == "trust level" })
            #expect(trust.level == .warn)
            #expect(trust.message == "FORCE CHECK: this text is wrong on purpose.")
            #expect(trust.fix == "run `darkbloom start`, then `darkbloom doctor`.")
            #expect(!diagnosis.contains { $0.section == .runtime })
            #expect(!diagnosis.contains { $0.section == .billing })
            #expect(diagnosis.first { $0.section == .version }?.message
                == "running \(ProviderCore.version); latest is 99.0.0.")
        }
    }
}
