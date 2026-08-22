import Foundation
import Testing
@testable import ProviderCore

@Suite("Gemma optimization reporting")
struct GemmaOptimizationReportingTests {
    @Test("reason precedence covers disabled, model eligibility, and AOT")
    func reasonPrecedence() {
        let report = GemmaOptimizationReport(
            layer18Requested: false,
            layer18Effective: false,
            weightedUnsortRequested: true,
            weightedUnsortEffective: false,
            safeR1Requested: true,
            safeR1GeometryEligible: true,
            safeR1AOTAvailable: false,
            safeR1NAXAvailable: true)

        #expect(report.layer18.reason == .disabled)
        #expect(report.weightedUnsort.reason == .modelIneligible)
        #expect(report.safeR1.reason == .aotUnavailable)
        #expect(!report.layer18.effective)
        #expect(!report.weightedUnsort.effective)
        #expect(!report.safeR1.effective)
    }

    @Test("NAX precedence and effective state render centrally")
    func naxAndEffectiveRendering() {
        let nax = GemmaOptimizationReport(
            layer18Requested: true,
            layer18Effective: true,
            weightedUnsortRequested: true,
            weightedUnsortEffective: true,
            safeR1Requested: true,
            safeR1GeometryEligible: true,
            safeR1AOTAvailable: true,
            safeR1NAXAvailable: true)
        #expect(nax.safeR1.reason == .naxPrecedence)
        #expect(!nax.safeR1.effective)

        let effective = GemmaOptimizationReport(
            layer18Requested: true,
            layer18Effective: true,
            weightedUnsortRequested: true,
            weightedUnsortEffective: true,
            safeR1Requested: true,
            safeR1GeometryEligible: true,
            safeR1AOTAvailable: true,
            safeR1NAXAvailable: false)
        let rendered = effective.logLine(modelId: "gemma-4-production")
        #expect(effective.states.allSatisfy { $0.effective })
        #expect(rendered.contains("layer18(requested=true,effective=true,reason=effective)"))
        #expect(rendered.contains("weighted_unsort(requested=true,effective=true,reason=effective)"))
        #expect(rendered.contains("safe_r1(requested=true,effective=true,reason=effective)"))

        let events = effective.telemetryEvents(modelId: "gemma-4-production")
        #expect(events.count == 3)
        #expect(events.allSatisfy { $0.kind == .engineHealth })
        #expect(events.allSatisfy { $0.fields?["model"]?.description == "gemma-4-production" })
        #expect(events.allSatisfy { $0.fields?["target"]?.description == "requested_1_effective_1" })
        #expect(events.allSatisfy { $0.fields?["reason"]?.description == "effective" })
        let allowedKeys = Set([
            "component", "operation", "backend", "model", "target", "reason",
        ])
        #expect(events.allSatisfy { Set($0.fields?.keys.map { $0 } ?? []) == allowedKeys })
    }
}

@Suite("Packaged retained-Gemma smoke")
struct PackagedRetainedGemmaSmokeTests {
    private let expectedProjection = [
        GemmaOptimizationEnvironment.prefillLayer18Key: "18",
        GemmaOptimizationEnvironment.weightedUnsortKey: "1",
        GemmaOptimizationEnvironment.safeR1Key: "1",
    ]

    @Test("synthetic retained config has an exact three-key projection")
    func exactProjectionAndNoRejectedKeys() throws {
        let config = try PackagedRuntimeSmoke.retainedConfiguration()
        // Mirror verifyGemmaOptimizations: the smoke validates the retained
        // config hermetically, never the launching environment.
        let decodedProjection = GemmaOptimizationEnvironment.projection(
            for: config.gemmaOptimizations,
            context: .retainedValidation)
        #expect(decodedProjection == expectedProjection)
        try PackagedRuntimeSmoke.validateRetainedProjection(decodedProjection)
        #expect(
            PackagedRuntimeSmoke.rejectedEnvironmentKeys(
                projection: expectedProjection,
                environment: expectedProjection).isEmpty)

        var poisoned = expectedProjection
        poisoned[GemmaOptimizationEnvironment.safeR1Key] = "poisoned"
        #expect(
            PackagedRuntimeSmoke.rejectedEnvironmentKeys(
                projection: expectedProjection,
                environment: poisoned)
                == [GemmaOptimizationEnvironment.safeR1Key])
    }

    @Test("retained validation is immune to an inherited trust override")
    func retainedValidationIgnoresInheritedTrust() throws {
        // BoundedProcess merges the parent environment into the smoke child,
        // so a foreground/local trust-mode provider (or installer shell) may
        // hand this process MLX_GATHER_QMM_EXPERT_SLICES=trust. The retained
        // projection must still be the exact safe-R1 posture, or SelfUpdater
        // artifact verification and paged-kernel preflight fail spuriously.
        let config = try PackagedRuntimeSmoke.retainedConfiguration()
        let projection = GemmaOptimizationEnvironment.projection(
            for: config.gemmaOptimizations,
            context: .retainedValidation,
            getenv: { key in
                key == GemmaOptimizationEnvironment.safeR1Key ? "trust" : nil
            }
        )
        #expect(projection == expectedProjection)
        try PackagedRuntimeSmoke.validateRetainedProjection(projection)

        // The serving projection of the same settings WOULD keep trust —
        // proving the two contexts diverge exactly on this one refinement.
        let serving = GemmaOptimizationEnvironment.projection(
            for: config.gemmaOptimizations,
            getenv: { key in
                key == GemmaOptimizationEnvironment.safeR1Key ? "trust" : nil
            }
        )
        #expect(serving[GemmaOptimizationEnvironment.safeR1Key] == "trust")
        #expect(throws: PackagedRuntimeSmoke.VerificationError.self) {
            try PackagedRuntimeSmoke.validateRetainedProjection(serving)
        }
    }

    @Test("safe R1 gate requires requested packaged AOT and unarmed counters")
    func safeR1Requirements() throws {
        try PackagedRuntimeSmoke.validateSafeR1(
            requested: true, aotAvailable: true, countersArmed: false)

        #expect(throws: PackagedRuntimeSmoke.VerificationError.safeR1NotRequested) {
            try PackagedRuntimeSmoke.validateSafeR1(
                requested: false,
                aotAvailable: true,
                countersArmed: false,
                probeMetalRuntime: { .healthy })
        }
        #expect(throws: PackagedRuntimeSmoke.VerificationError.safeR1AOTUnavailable) {
            try PackagedRuntimeSmoke.validateSafeR1(
                requested: true, aotAvailable: false, countersArmed: false)
        }
        #expect(throws: PackagedRuntimeSmoke.VerificationError.safeR1CountersArmed) {
            try PackagedRuntimeSmoke.validateSafeR1(
                requested: true, aotAvailable: true, countersArmed: true)
        }
    }

    // Regression for the macOS 15 install failure: the C diagnostics facade
    // reports an unrequested route whenever `metal::device(gpu)` throws, so an
    // unloadable packaged metallib used to surface as "safe R1 was not latched
    // as requested" and sent every reader after a latch bug that did not exist.
    @Test("an unusable Metal runtime is reported instead of a latch failure")
    func unrequestedRouteBlamesTheMetalRuntime() throws {
        let diagnosis = MetalRuntimeDiagnosis.noLoadableMetallib(
            hostOS: "15.7.9",
            attempts: [
                PackagedMetallibAttempt(
                    path: "/Darkbloom.app/Contents/MacOS/mlx.metallib",
                    failure: "Metal library is not supported on this OS"),
            ])
        #expect(
            throws: PackagedRuntimeSmoke.VerificationError
                .metalRuntimeUnavailable(diagnosis)
        ) {
            try PackagedRuntimeSmoke.validateSafeR1(
                requested: false,
                aotAvailable: false,
                countersArmed: false,
                probeMetalRuntime: { diagnosis })
        }
        #expect(diagnosis.description.contains("15.7.9"))
        #expect(
            diagnosis.description.contains(
                "macOS \(PackagedMetallib.minimumMacOSVersion) or later"))
        #expect(diagnosis.description.contains("mlx.metallib"))
    }

    @Test("no Metal device at all is named as such")
    func missingDeviceIsNamed() {
        let diagnosis = MetalRuntimeProbe.classify(
            executableDirectory: URL(fileURLWithPath: "/nonexistent"),
            hostOS: "15.7.9",
            loader: nil)
        #expect(diagnosis == .noMetalDevice)
        #expect(!diagnosis.isHealthy)
        #expect(diagnosis.description.contains("no Metal device"))
    }

    // The whole point of shipping two libraries: the primary is rejected by an
    // older Metal runtime and the colocated `Resources/mlx.metallib` fallback
    // — MLX's own second probe — has to carry the process.
    @Test("baseline fallback rescues a rejected primary metallib")
    func baselineFallbackIsHealthy() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("metallib-probe-\(UUID().uuidString)")
        let fm = FileManager.default
        try fm.createDirectory(
            at: root.appendingPathComponent("Resources"),
            withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        for path in PackagedMetallib.relativePaths {
            try Data("metallib".utf8).write(
                to: root.appendingPathComponent(path))
        }

        var loaded: [String] = []
        let diagnosis = MetalRuntimeProbe.classify(
            executableDirectory: root,
            hostOS: "15.7.9",
            loader: { url in
                loaded.append(url.lastPathComponent)
                // Only the macOS 26.2 primary is rejected here.
                return loaded.count == 1
                    ? "Metal library is not supported on this OS" : nil
            })
        #expect(diagnosis == .healthy)
        #expect(loaded.count == 2)

        // Without the baseline the same host has nothing left to fall back to.
        try fm.removeItem(
            at: root.appendingPathComponent(PackagedMetallib.relativePaths[1]))
        let unrescued = MetalRuntimeProbe.classify(
            executableDirectory: root,
            hostOS: "15.7.9",
            loader: { _ in "Metal library is not supported on this OS" })
        #expect(!unrescued.isHealthy)
        #expect(unrescued.description.contains("not present"))
    }

    @Test("signed-child marker is an exact output line")
    func signedChildMarker() {
        let exact = Data(
            "noise\n\(PackagedRuntimeSmoke.gemmaOptimizationSuccessMarker)\npaged-kernel-runtime-smoke: ok\n".utf8)
        let embedded = Data(
            "prefix-\(PackagedRuntimeSmoke.gemmaOptimizationSuccessMarker)-suffix\n".utf8)
        #expect(PackagedRuntimeSmoke.containsGemmaOptimizationSuccessMarker(exact))
        #expect(!PackagedRuntimeSmoke.containsGemmaOptimizationSuccessMarker(embedded))
    }
}
