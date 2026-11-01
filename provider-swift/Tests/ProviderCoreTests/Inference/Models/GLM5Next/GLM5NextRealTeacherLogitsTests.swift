import Foundation
import MLX
import MLXVLM
import MLXLMCommon
import Testing

@_spi(Benchmarking) @testable import ProviderCore

struct GLM5NextTeacherPanel: Decodable, Sendable {
    struct Row: Decodable, Sendable {
        let id: String
        let promptTokens: [Int]
        let nextToken: Int
        let teacherLogits: [Double]
    }
    let dataset: String
    let revision: String
    let license: String
    let licenseAccepted: Bool
    let panel: String
    let rows: [Row]
}

@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["DARKBLOOM_TEST_GLM5_REAL_QUALITY"] == "1"))
struct GLM5NextRealTeacherLogitsTests {
    @Test func realFirstStepLogitsAgainstPublicBF16Teacher() async throws {
        let env = ProcessInfo.processInfo.environment
        let url = URL(fileURLWithPath: try #require(env["DARKBLOOM_TEST_GLM5_REAL_TEACHER_PANEL"]))
        let panelData = try Data(contentsOf: url)
        let panel = try JSONDecoder().decode(GLM5NextTeacherPanel.self, from: panelData)
        try #require(panel.dataset == "brandonmusic/GLM-5.3-Flash-BF16-Teacher-Logits")
        try #require(panel.revision == "95f4fdd94bf29989db2e0d1054e4931f55edb6aa")
        try #require(panel.license == "other" && panel.licenseAccepted && panel.panel == "selection")
        try #require(!panel.rows.isEmpty && panel.rows.count <= 128)
        try await GLM5NextRealModelHarness.withLoaded { harness in
            let container = try #require(harness.container)
            var records: [[String: Any]] = []
            for (index, row) in panel.rows.enumerated() {
                try #require(row.teacherLogits.count == 154880 && row.teacherLogits.allSatisfy(\.isFinite))
                try #require(!row.promptTokens.isEmpty && row.promptTokens.count <= 2047)
                try GLM5NextExecutionBound.validateRequest(promptTokens: row.promptTokens.count,
                    maximumOutputTokens: 1, limit: harness.maximumContext)
                try #require(row.promptTokens.allSatisfy { (0..<154880).contains($0) })
                try #require((0..<154880).contains(row.nextToken))
                // Diagnostic forward on the managed root, with an isolated
                // cache and bounded chunks. Never retains full-window logits.
                let activity = harness.budget.serviceBudget.beginUnboundedActivity()
                let student: [Float]
                do {
                    student = try await container.perform { context in
                        let root = try #require(context.model as? GLM5NextModel)
                        return try MLX.withError { errors in
                            let cache = root.newTextCache()
                            var last: [Float] = []
                            for start in stride(from: 0, to: row.promptTokens.count, by: 128) {
                                let tokens = Array(row.promptTokens[start..<min(start + 128, row.promptTokens.count)])
                                let output = try root.textTower.forward(
                                    tokens: MLXArray(tokens.map(Int32.init)).reshaped([1, tokens.count]), cache: cache)
                                let logits = output.logits[0, -1, 0...].asType(.float32)
                                eval(logits); try errors.check()
                                last = logits.asArray(Float.self); try errors.check()
                            }
                            return last
                        }
                    }
                    activity.finish()
                } catch { activity.finish(); throw error }
                try #require(student.count == 154880 && student.allSatisfy(\.isFinite))
                let s = student.map(Double.init), t = row.teacherLogits
                func logZ(_ x: [Double]) -> Double {
                    let maximum = x.max()!
                    return maximum + log(x.reduce(0) { $0 + exp($1 - maximum) })
                }
                let tz = logZ(t), sz = logZ(s)
                let kld = zip(t, s).reduce(0.0) { $0 + exp($1.0 - tz) * (($1.0 - tz) - ($1.1 - sz)) }
                func top(_ values: [Double]) -> [Int] {
                    values.indices.sorted { values[$0] == values[$1] ? $0 < $1 : values[$0] > values[$1] }.prefix(5).map { $0 }
                }
                let teacherTop = top(t), studentTop = top(s)
                // Gross corruption bounds, NOT a Q4 quality certification or
                // comparison with another runtime's unmeasured BF16 lane floor.
                #expect(kld.isFinite && kld >= -1e-8 && kld < 100)
                let served = try await harness.run(row.promptTokens, id: UInt64(300 + index), output: 1,
                    suppressEOS: true)
                #expect(served.reason == .length && served.tokens == [studentTop[0]],
                    "managed paged path must agree with the native reference first step")
                records.append(["id": row.id, "contextTokens": row.promptTokens.count,
                    "promptSHA256": GLM5NextRealModelHarness.tokenHash(row.promptTokens),
                    "kldTeacherStudentNats": kld, "top1Agreement": teacherTop[0] == studentTop[0],
                    "top5Overlap": Double(Set(teacherTop).intersection(studentTop).count) / 5,
                    "teacherTop5": teacherTop, "studentTop5": studentTop,
                    "deltaNLL": (sz - s[row.nextToken]) - (tz - t[row.nextToken])])
                try harness.write("teacher-quality", ["schema": 1, "qualified": false,
                    "scope": "fixed-selection-prefix-first-step-not-full-panel",
                    "teacherPanelSHA256": GLM5NextRealModelHarness.hash(panelData),
                    "aggregateSHA256": harness.plan.weights.manifest.aggregateSHA256,
                    "records": records,
                    "meanKLD": records.compactMap { $0["kldTeacherStudentNats"] as? Double }.reduce(0, +) / Double(records.count),
                    "top1Agreement": Double(records.filter { $0["top1Agreement"] as? Bool == true }.count) / Double(records.count)])
            }
        }
    }
}
