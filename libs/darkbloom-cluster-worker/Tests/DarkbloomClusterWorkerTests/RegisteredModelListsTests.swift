import DarkbloomClusterPrompt
import DarkbloomClusterProtocol
import DarkbloomClusterQualification
import DarkbloomClusterRuntime
import Foundation
import XCTest
@testable import DarkbloomClusterWorker

/// A registered model is named in closed lists that live in three packages
/// and do not all link each other: the runtime's catalog, the protocol's
/// adapter pairs, the qualification tool's request models and the prompt
/// tool's manifest pins. This holds them to one another, so a model added to
/// the runtime and forgotten anywhere else fails here by name. The cuts in the
/// tools' usage texts are read from the catalog and are checked as that.
final class RegisteredModelListsTests: XCTestCase {
    func testEveryRegisteredModelIsInEveryClosedList() throws {
        // Every family's closed rows, the Qwen catalog first.
        let runtime = RegisteredResidentModels.all
        let identifiers = runtime.map(\.runtimeModelID)
        XCTAssertGreaterThanOrEqual(runtime.count, 3)
        XCTAssertEqual(Set(identifiers).count, identifiers.count, "a runtime model ID is registered twice")

        // The protocol: every adapter pair is a runtime row and the reverse.
        let admitted = ClusterRuntimeAdapter.admittedModels
        XCTAssertEqual(admitted.map { "\($0.runtimeModelID) \($0.profileID)" }.sorted(),
                       runtime.map { "\($0.runtimeModelID) \($0.profileID)" }.sorted(),
                       "ClusterRuntimeAdapter.registeredProfiles and the runtime catalog differ")

        // The qualification request models, in the catalog's order.
        XCTAssertEqual(QualificationRequest.registeredModels.map(\.modelID), identifiers,
                       "QualificationRequest.registeredModels and the runtime catalog differ")
        // The prompt tool's manifest pins: one per model, the runtime's own pin.
        XCTAssertEqual(PromptTokenizer.registeredManifests.map(\.modelID), identifiers,
                       "PromptTokenizer.registeredManifests and the runtime catalog differ")
        XCTAssertEqual(Set(PromptTokenizer.registeredManifests.map(\.sha256)).count, identifiers.count)

        let common = Dictionary(uniqueKeysWithValues: PairConfiguration.arithmeticEnvironment.map { ($0.0, $0.1) })
        let usage = RegisteredResidentModels.registeredCutsUsage
        for model in runtime {
            let name = model.runtimeModelID
            let request = try XCTUnwrap(QualificationRequest.registeredModel(name), "\(name) has no qualification request row")
            XCTAssertEqual(request.profileID, model.profileID, name)
            XCTAssertEqual(request.supportedCuts, model.supportedCuts, name)
            XCTAssertEqual(common.merging(request.additionalArithmeticEnvironment) { $1 }, model.requiredArithmeticEnvironment,
                           "\(name): the driver would start a rank outside the model's arithmetic contract")
            XCTAssertTrue(Set(request.additionalArithmeticEnvironment.keys).isDisjoint(with: common.keys), name)
            XCTAssertEqual(PromptTokenizer.registeredManifests.first { $0.modelID == name }?.sha256, model.manifestSHA256, name)
            XCTAssertTrue(usage.split(separator: "\n").contains(Substring(
                "\(name): " + model.supportedCuts.map(String.init).joined(separator: "|"))), "\(name) is missing from the usage text")
            // The worker accepts exactly the model's cuts, on either rank.
            for cut in stride(from: 0, through: model.layerCount + 4, by: 2) {
                let arguments = ["--model-dir", "/invented/model", "--rank", "1", "--stage-cut", String(cut),
                    "--membership-epoch", "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee", "--model-id", name,
                    "--artifact-sha256", String(repeating: "a", count: 64), "--configuration-sha256", String(repeating: "b", count: 64),
                    "--peer0-id", "one", "--peer0-build-sha256", String(repeating: "c", count: 64),
                    "--peer1-id", "two", "--peer1-build-sha256", String(repeating: "d", count: 64),
                    "--deadline-uptime-nanoseconds", "300000000100"]
                if model.supportedCuts.contains(cut) {
                    XCTAssertEqual(try WorkerConfiguration(arguments: arguments, now: 100).load.stageCut, cut, name)
                    for mode in model.supportedGenerationModes {
                        XCTAssertEqual(try WorkerConfiguration(arguments: arguments + ["--generation-mode", mode.rawValue], now: 100)
                            .generationMode, mode, name)
                    }
                } else {
                    XCTAssertThrowsError(try WorkerConfiguration(arguments: arguments, now: 100), "\(name) cut \(cut)")
                }
            }
        }
    }

    /// The two tools that print cuts take them from the catalog; neither
    /// carries a list of its own that could fall behind it.
    func testToolUsageTextsReadTheirCutsFromTheCatalog() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources")
        for path in ["StageLoadCheck/StageLoadCheck.swift", "ReferenceCheck/ReferenceCheck.swift"] {
            let text = try String(contentsOf: sources.appendingPathComponent(path), encoding: .utf8)
            XCTAssertTrue(text.contains("RegisteredResidentModels.registeredCutsUsage"), path)
            XCTAssertNil(text.range(of: #"\d+\|\d+\|\d+"#, options: .regularExpression), "\(path) spells cuts out itself")
        }
    }

    func testRoutedExpertModelArgumentsAndCrossedModelCuts() throws {
        var arguments = ["--model-dir", "/invented/model", "--rank", "0", "--stage-cut", "20",
            "--membership-epoch", "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee", "--model-id", "registered_qwen35_35b_a3b",
            "--artifact-sha256", String(repeating: "a", count: 64), "--configuration-sha256", String(repeating: "b", count: 64),
            "--peer0-id", "one", "--peer0-build-sha256", String(repeating: "c", count: 64),
            "--peer1-id", "two", "--peer1-build-sha256", String(repeating: "d", count: 64),
            "--deadline-uptime-nanoseconds", "300000000100"]
        let value = try WorkerConfiguration(arguments: arguments, now: 100)
        XCTAssertEqual(value.load.identity.modelID, "registered_qwen35_35b_a3b")
        XCTAssertEqual(value.load.allocatorPolicy, .disableFreedBufferCache); XCTAssertEqual(value.generationMode, .pipeline)
        XCTAssertEqual(try WorkerConfiguration(arguments: arguments + ["--prefill-schedule", "one_chunk_lookahead_v1"], now: 100)
            .load.prefillSchedule, .oneChunkLookahead)
        for cut in ["0", "2", "38", "40", "44", "020", "+20", "20.0"] {
            arguments[5] = cut
            XCTAssertThrowsError(try WorkerConfiguration(arguments: arguments, now: 100), "cut \(cut)")
        }
        // Its cuts above 16 stay closed to the 9B, and the catalog's public
        // name is not a runtime model ID.
        arguments[5] = "20"; arguments[9] = "registered_qwen35_9b"
        XCTAssertThrowsError(try WorkerConfiguration(arguments: arguments, now: 100))
        for model in ["qwen3.5-35b-a3b", "registered_qwen35_35b_a3b ", "registered_qwen35_35b", "registered_qwen36_35b_a3b_v2"] {
            arguments[9] = model
            XCTAssertThrowsError(try WorkerConfiguration(arguments: arguments, now: 100), "model \(model)")
        }
    }
}
