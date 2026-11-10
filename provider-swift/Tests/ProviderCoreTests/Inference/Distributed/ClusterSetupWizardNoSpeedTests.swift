import Foundation
import Testing

@testable import ProviderCore

/// The six-step developer wizard (`darkbloom cluster --wizard`) quotes no speed where the person chooses a model or
/// reads the check that gates serving (owner, 2026-11-05: "it should not show tok/s"; the model and mode choice never
/// quote tok/s). A test prompt the person types and sends from its last step still reports what that request measured.
@Suite("Setup wizard: no speed on the model choice or the check")
struct ClusterSetupWizardNoSpeedTests {
    static let configuration = String(repeating: "a", count: 64)

    static func plan(absolute: Bool) -> ClusterSetupPlanSummary {
        func rank(_ rank: Int, _ member: String) -> ClusterSetupPlanSummary.Rank {
            .init(rank: rank, memberID: member, local: rank == 0, firstLayer: rank * 15, endLayer: (rank + 1) * 15, weightsBytes: 8 << 30,
                  needBytes: 9 << 30, admissibleNowBytes: 100 << 30, physicalMemoryBytes: 128 << 30, fit: "now", fitDetail: "fits now",
                  shortBytes: nil)
        }
        return .init(cut: 15, mode: "pipeline_v1", prefillSchedule: "serial_v1", leaderID: "mac-a", ranks: [rank(0, "mac-a"), rank(1, "mac-b")],
                     promptTokens: 8_192, outputTokens: 256, firstTokenSeconds: 1.2, decodeTokensPerSecond: 95.4, absolute: absolute,
                     measured: absolute,
                     alone: [.init(memberID: "mac-a", fitsNow: true, holds: true, firstTokenSeconds: 0.9, decodeTokensPerSecond: 126.4),
                             .init(memberID: "mac-b", fitsNow: false, holds: true, firstTokenSeconds: 1.1, decodeTokensPerSecond: 80.2)],
                     aloneAsFast: [], fitsNow: true, needsBytes: nil, explanation: [])
    }

    /// Step 4's model list and the selected model's plan, as text.
    static func modelStep(_ plan: ClusterSetupPlanSummary) -> String {
        var builder = ClusterSetupContent.Builder(width: 120, glyphs: .unicode, interactive: false)
        let model = ClusterSetupLocalModel(folder: "gemma-4-26b-qat-4bit-r1", modelID: "gemma-4-26b-qat-4bit", version: "r1",
                                           artifactSHA256: String(repeating: "b", count: 64), totalBytes: 15_600_000_000)
        ClusterSetupContent.modelList(ClusterSetupState(size: .init(columns: 120, rows: 60)),
                                      [.init(model: model, onOtherMac: true, blocker: nil, plan: plan)], &builder)
        return builder.lines.map(\.text).joined(separator: "\n")
    }

    /// Step 5 on the leading Mac, as text.
    static func checkStep(_ change: (inout ClusterSetupState) -> Void) -> String {
        let setup = ClusterSetupSetupSummary(configurationSHA256: configuration, clusterID: "pair", memberID: "mac-a", role: "leader",
            localRank: 0, peerID: "mac-b", linkDevice: "rdma_en7", publicModelID: "gemma-4-26b-qat-4bit",
            runtimeModelID: "registered_gemma4_26b", artifactSHA256: String(repeating: "b", count: 64),
            planSHA256: String(repeating: "c", count: 64), generationMode: "pipeline_v1", prefillSchedule: "serial_v1",
            stages: [.init(rank: 0, memberID: "mac-a", firstLayer: 0, endLayer: 15), .init(rank: 1, memberID: "mac-b", firstLayer: 15, endLayer: 30)],
            knownHostsPinMatches: true, identityFileUsable: true, workerVerified: true, progressGuard: true, workerDetail: nil,
            filesPresent: 12, filesExpected: 12, holdings: nil)
        let report = ClusterSetupReport(observedAt: "2026-11-06T00:00:00Z", version: "fixture",
            mac: .init(profile: nil, profileError: nil, chip: "Apple M3 Ultra", physicalMemoryBytes: 256 << 30, osVersion: "27.2",
                       osMajor: 27, osMinor: 2, diskFreeBytes: nil, diskTotalBytes: nil),
            link: .init(state: "ready", guidance: nil, port: nil, portsDown: 0, thunderbolt: nil, thunderboltError: nil),
            saved: .init(state: .loaded, error: nil, setup: setup), inbox: nil, journal: .absent,
            memoryGuard: .init(decision: .clear, wiredBytes: nil, baselineBytes: nil, detail: nil),
            models: [], modelsError: nil, pairingCode: nil, checks: [])
        var record = ClusterSetupRecord()
        record.add(.init(configurationSHA256: configuration, at: "2026-11-06T00:01:00Z", readySeconds: 11.2, firstTokenMilliseconds: 720,
                         tokensPerSecond: 53.1))
        var state = ClusterSetupState(size: .init(columns: 120, rows: 60))
        state.snapshot = .init(local: report, pair: nil, pairError: nil, record: record, recordError: nil)
        change(&state)
        var builder = ClusterSetupContent.Builder(width: 120, glyphs: .unicode, interactive: false)
        ClusterSetupContent.check(state, report, &builder)
        return builder.lines.map(\.text).joined(separator: "\n")
    }

    @Test("the model step: measured or estimated, no speed and no time; which Mac holds it alone")
    func theModelStepQuotesNoSpeed() {
        let measured = Self.modelStep(Self.plan(absolute: true))
        #expect(!measured.contains("tok/s") && !measured.contains("first token") && !measured.contains("Predicted"), "\(measured)")
        #expect(measured.contains("fits now") && measured.contains("mac-a holds it") && measured.contains("mac-b holds it (not now)"),
                "\(measured)")
        let relative = Self.modelStep(Self.plan(absolute: false))
        #expect(!relative.contains("tok/s") && relative.contains("speed was not measured for this model on these Macs, so the split follows memory"),
                "\(relative)")
    }

    @Test("the check: its tokens and the first token's time, no speed; a test prompt keeps the speed it measured")
    func theCheckQuotesNoSpeed() {
        let generated = Self.checkStep { state in
            state.check = .running(.stop, since: 0)
            state.checkPrompt = .init(completionTokens: 8, firstTokenMilliseconds: 720, tokensPerSecond: 53.1, finishReason: "length")
        }
        #expect(generated.contains("8 tokens \u{B7} first token 0.72 s") && !generated.contains("tok/s"), "\(generated)")
        let passed = Self.checkStep { _ in }
        #expect(passed.contains("Passed 2026-11-06T00:01:00Z on this setup: ready in 11.2 s, first token 0.72 s.") && !passed.contains("tok/s"),
                "\(passed)")
        // Kept: the person sent this prompt; the line reports what that request measured.
        let prompt = ClusterSetupState.describe(.init(completionTokens: 12, firstTokenMilliseconds: 610, tokensPerSecond: 52.4, finishReason: "stop"))
        #expect(prompt == "12 tokens \u{B7} first token 0.61 s \u{B7} 52.4 tok/s \u{B7} finished: stop")
    }
}
