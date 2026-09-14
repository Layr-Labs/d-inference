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
        // This exact projection is passed before exec and revalidated inside
        // the child, so eager MLX initialization cannot latch stale values.
        let decodedProjection = try PackagedRuntimeSmoke.retainedValidationEnvironment()
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
                requested: false, aotAvailable: true, countersArmed: false)
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
