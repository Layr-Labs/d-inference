import Foundation
import DarkbloomClusterProtocol
import DarkbloomClusterProcess
@testable import InstalledContract

extension InstalledSessionCheck {
    static func startupPreparation(_ base: InstalledFixture) async throws {
        let recipe = ClusterRuntimeStartupPreparation(tokenPattern: [1], outputCount: 2)
        let f = try InstalledFixture.make(root: base.root.appendingPathComponent("with-startup"),
            probe: base.probe, owner: base.owner, worker: base.worker, startupPreparation: recipe)
        let prepared = try f.prepare()
        let (s, _) = try session(f, prepared)
        try require(s.readiness() == nil && s.startupPreparationResult == nil, "Preparation fabricated readiness")
        try await s.start()
        guard let result = s.startupPreparationResult else { throw CheckFailure(message: "Startup receipt missing") }
        try require(s.status == .ready && s.readiness() != nil && s.admissionState?.admissionsRemaining == 15,
                    "Warmup failed to consume one of the unchanged sixteen admissions")
        try require(result.promptTokens == f.configuration.chunkTokens && result.selectedTokens == 2
            && result.reservedBytes == 1600 && result.admissionsRemaining == 15
            && result.elapsedNanoseconds > 0 && s.admissionState?.hasActiveRequest == false,
            "Warmup geometry, actual reservation or explicit release differs")
        try require(s.admissionState!.remainingLifetimeNanoseconds < 10_000_000_000,
                    "Warmup refreshed the fixed lifetime")
        for id in 1001...1015 {
            let lease = try request(s, UInt64(id))
            try lease.start { _ in true }; await lease.waitUntilRetired(); lease.releaseResources()
        }
        try require(s.admissionState?.admissionsRemaining == 0 && s.readiness() == nil,
                    "Warmup silently became a seventeenth admission")
        try rejected { _ = try request(s, 1016) }
        try require(await s.stop(until: DispatchTime.now().uptimeNanoseconds + 5_000_000_000) == .released,
                    "Warm session did not release its owners")

        let (cancelled, cancelledEndpoints) = try session(f, prepared, behavior: "hang")
        let startup = Task { try await cancelled.start() }
        let until = ContinuousClock.now.advanced(by: .seconds(5))
        while !(cancelled.status == .warming && cancelled.admissionState?.hasActiveRequest == true)
                && ContinuousClock.now < until { try await Task.sleep(for: .milliseconds(10)) }
        try require(cancelled.status == .warming && cancelled.readiness() == nil
            && !cancelled.diagnosticObservation.ready && cancelled.startupPreparationResult == nil
            && cancelled.admissionState?.admissionsRemaining == 15,
            "Running startup was advertised as ready or omitted from quota")
        let stopped = await cancelled.stop(until: DispatchTime.now().uptimeNanoseconds + 6_000_000_000)
        do { try await startup.value; throw CheckFailure(message: "Cancelled startup succeeded") }
        catch is CheckFailure { throw CheckFailure(message: "Cancelled startup succeeded") } catch {}
        try require(cancelled.readiness() == nil && cancelled.startupPreparationResult == nil
            && [.released, .quarantined].contains(stopped)
            && cancelledEndpoints.snapshot.allSatisfy(\.nativeCleanupObserved),
            "Cancelled warmup lost retained actual cleanup")
        try require(!cancelled.canRotate || cancelledEndpoints.snapshot.allSatisfy(\.ownerDeviceLeaseReleasedObserved),
                    "Warmup cancellation manufactured owner release")

        let (taskCancelled, taskEndpoints) = try session(f, prepared, behavior: "hang")
        let cancelledTask = Task { try await taskCancelled.start() }
        let taskUntil = ContinuousClock.now.advanced(by: .seconds(5))
        while !(taskCancelled.status == .warming && taskCancelled.admissionState?.hasActiveRequest == true)
                && ContinuousClock.now < taskUntil { try await Task.sleep(for: .milliseconds(10)) }
        try require(taskCancelled.status == .warming && taskCancelled.admissionState?.hasActiveRequest == true,
                    "Task cancellation fixture did not enter admitted startup")
        cancelledTask.cancel()
        do { try await cancelledTask.value; throw CheckFailure(message: "Cancelled startup task succeeded") }
        catch is CheckFailure { throw CheckFailure(message: "Cancelled startup task succeeded") } catch {}
        _ = await taskCancelled.stop(until: DispatchTime.now().uptimeNanoseconds + 6_000_000_000)
        try require(taskCancelled.readiness() == nil && taskCancelled.startupPreparationResult == nil
            && taskEndpoints.snapshot.allSatisfy(\.nativeCleanupObserved),
            "Task cancellation left warmup externally ready or without actual cleanup")
        try require(!taskCancelled.canRotate || taskEndpoints.snapshot.allSatisfy(\.ownerDeviceLeaseReleasedObserved),
                    "Task cancellation manufactured owner release")

        let (failed, failedEndpoints) = try session(f, prepared, behavior: "exit")
        do { try await failed.start(); throw CheckFailure(message: "Failed startup forward succeeded") }
        catch is CheckFailure { throw CheckFailure(message: "Failed startup forward succeeded") } catch {}
        _ = await failed.stop(until: DispatchTime.now().uptimeNanoseconds + 6_000_000_000)
        try require(failed.readiness() == nil && failed.startupPreparationResult == nil
            && failed.admissionState?.admissionsRemaining == 15
            && failedEndpoints.snapshot.allSatisfy(\.nativeCleanupObserved),
            "Failed recipe published readiness, restored quota or lost cleanup")
        try require(!failed.canRotate || failedEndpoints.snapshot.allSatisfy(\.ownerDeviceLeaseReleasedObserved),
                    "Failed recipe manufactured owner release")

        let short = try InstalledFixture.make(root: base.root.appendingPathComponent("startup-short-life"),
            probe: base.probe, owner: base.owner, worker: base.worker, lifetimeSeconds: 3, startupPreparation: recipe)
        let (expired, endpoints) = try session(short, short.prepare(), behavior: "hang")
        let expiringStartup = Task { try await expired.start() }
        let warmingUntil = ContinuousClock.now.advanced(by: .seconds(2))
        while !(expired.status == .warming && expired.admissionState?.hasActiveRequest == true)
                && ContinuousClock.now < warmingUntil { try await Task.sleep(for: .milliseconds(10)) }
        try require(expired.status == .warming && expired.admissionState?.hasActiveRequest == true,
                    "Expiry fixture did not enter admitted startup")
        let originalDeadline = expired.lifetimeDeadlineUptimeNanoseconds
        do { try await expiringStartup.value; throw CheckFailure(message: "Expired warmup succeeded") }
        catch is CheckFailure { throw CheckFailure(message: "Expired warmup succeeded") } catch {}
        try require(expired.readiness() == nil && expired.startupPreparationResult == nil
            && expired.admissionState?.remainingLifetimeNanoseconds == 0
            && expired.lifetimeDeadlineUptimeNanoseconds == originalDeadline,
            "Expired startup extended its lifetime or published readiness")
        _ = await expired.stop(until: DispatchTime.now().uptimeNanoseconds + 6_000_000_000)
        try require(endpoints.snapshot.allSatisfy(\.nativeCleanupObserved), "Expired warmup lacks actual cleanup")
        try require(!expired.canRotate || endpoints.snapshot.allSatisfy(\.ownerDeviceLeaseReleasedObserved),
                    "Expired recipe manufactured owner release")
    }
}
