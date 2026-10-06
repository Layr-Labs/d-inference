// Benchmark entry points that must refuse bad input before they load a
// model, hash a runtime or build an engine. Every fixture is a temporary
// folder that the test removes.

import Foundation
import Testing

@testable import ProviderBenchmark
@testable import ProviderCore

@Suite("benchmark entry points refuse bad input before model work")
struct BenchmarkEntryPointRefusalTests {
    private let hardware = HardwareInfo(
        machineModel: "fixture", chipName: "fixture", chipFamily: .m4, chipTier: .max,
        memoryGb: 128, memoryAvailableGb: 124,
        cpuCores: CpuCores(total: 16, performance: 12, efficiency: 4),
        gpuCores: 40, memoryBandwidthGbs: 546)

    private func temporaryDirectory(_ label: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    // MARK: - Ordinary benchmark

    @Test("the ordinary benchmark refuses empty budgets and a missing config")
    func ordinaryBenchmarkRefusals() async throws {
        let directory = try temporaryDirectory("ordinary-benchmark")
        defer { try? FileManager.default.removeItem(at: directory) }
        for (iterations, maxTokens) in [(0, 8), (2, 0)] {
            do {
                _ = try await ModelBenchmark.run(
                    modelID: "fixture", modelDirectory: directory, iterations: iterations,
                    maxTokens: maxTokens, hardware: hardware)
                Issue.record("budget \(iterations)/\(maxTokens) was accepted")
            } catch {
                #expect((error as? ModelBenchmark.Failure) == .invalidArguments)
            }
        }
        do {
            _ = try await ModelBenchmark.run(
                modelID: "fixture", modelDirectory: directory, iterations: 1, maxTokens: 1,
                hardware: hardware)
            Issue.record("a missing config was accepted")
        } catch {
            #expect((error as? CocoaError)?.code == .fileReadNoSuchFile)
        }
    }

    @Test("the native Qwen route refuses a folder with no weights or a non-native type")
    func nativeQwenRefusals() async throws {
        let empty = try temporaryDirectory("native-empty")
        let gemma = try temporaryDirectory("native-gemma")
        defer {
            try? FileManager.default.removeItem(at: empty)
            try? FileManager.default.removeItem(at: gemma)
        }
        try Data(#"{"model_type": "gemma4"}"#.utf8)
            .write(to: gemma.appendingPathComponent("config.json"))
        try Data("weights".utf8).write(to: gemma.appendingPathComponent("model.safetensors"))
        for directory in [empty, gemma] {
            do {
                _ = try await ModelBenchmark.runNativeQwen4(
                    modelID: "fixture", modelDirectory: directory, prompt: "hi",
                    iterations: 1, maxTokens: 1)
                Issue.record("\(directory.lastPathComponent) was accepted")
            } catch {
                #expect((error as? ModelBenchmark.Failure) == .modelHashMismatch)
            }
        }
    }

    // MARK: - MTP bundle

    @Test("the MTP bundle refuses a target with no safetensors weights")
    func mtpBundleRefusal() async throws {
        let target = try temporaryDirectory("mtp-target")
        let assistant = try temporaryDirectory("mtp-assistant")
        defer {
            try? FileManager.default.removeItem(at: target)
            try? FileManager.default.removeItem(at: assistant)
        }
        try Data(#"{"model_type": "gemma4"}"#.utf8)
            .write(to: target.appendingPathComponent("config.json"))
        do {
            _ = try await MTPProductionModelBundle.load(
                targetID: "fixture/target", targetDirectory: target,
                assistantID: "fixture/assistant", assistantDirectory: assistant)
            Issue.record("a target with no weights was accepted")
        } catch let error as MTPBenchmarkError {
            guard case .artifactIdentity(let reason) = error else {
                Issue.record("unexpected error: \(error)")
                return
            }
            #expect(reason == "artifact has no safetensors weights")
        }
    }

    // MARK: - Teacher-forced scoring

    @Test("teacher-forced scoring refuses a bad backend, input, hash or declaration")
    func teacherForcedRefusals() async throws {
        let root = try temporaryDirectory("teacher-forced")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = root.appendingPathComponent("model", isDirectory: true)
        try FileManager.default.createDirectory(at: model, withIntermediateDirectories: true)
        let inputURL = root.appendingPathComponent("input.json")

        func run(backend: String = "contiguous", modelID: String = "target") async -> Error? {
            do {
                _ = try await TeacherForcedBenchmark.run(
                    modelID: modelID, modelDirectory: model, inputURL: inputURL,
                    backend: backend, gemmaOptimizations: GemmaOptimizationSettings())
                return nil
            } catch {
                return error
            }
        }
        func writeInput(hash: String) throws {
            let input = TeacherForcedBenchmarkInput(
                modelID: "target", expectedModelAggregateSHA256: hash,
                promptTokens: [1, 2], continuation: [9])
            try JSONEncoder().encode(input).write(to: inputURL)
        }

        let backend = await run(backend: "auto")
        #expect((backend as? TeacherForcedBenchmark.Failure) == .explicitBackendRequired)

        let missingInput = await run()
        #expect(missingInput != nil)
        #expect(!(missingInput is TeacherForcedBenchmark.Failure))

        try writeInput(hash: String(repeating: "a", count: 64))
        let identity = await run(modelID: "other")
        #expect((identity as? TeacherForcedBenchmark.Failure) == .invalidInputIdentity)

        try Data(#"{"model_type": "fixture"}"#.utf8)
            .write(to: model.appendingPathComponent("config.json"))
        let mismatch = await run()
        #expect((mismatch as? TeacherForcedBenchmark.Failure) == .modelHashMismatch)

        let undeclared = try #require(WeightHasher.computeHash(snapshotDir: model, modelID: "target"))
        try writeInput(hash: undeclared)
        let declaration = await run()
        #expect((declaration as? TeacherForcedBenchmark.Failure) == .invalidDeclaration)

        // Token 9 is outside a four-token vocabulary, so the request fails
        // after the declaration is read and before any runtime work.
        try Data(#"{"model_type": "fixture", "vocab_size": 4}"#.utf8)
            .write(to: model.appendingPathComponent("config.json"))
        let declared = try #require(WeightHasher.computeHash(snapshotDir: model, modelID: "target"))
        try writeInput(hash: declared)
        let vocabulary = await run()
        #expect(vocabulary != nil)
        #expect(!(vocabulary is TeacherForcedBenchmark.Failure))
    }
}
