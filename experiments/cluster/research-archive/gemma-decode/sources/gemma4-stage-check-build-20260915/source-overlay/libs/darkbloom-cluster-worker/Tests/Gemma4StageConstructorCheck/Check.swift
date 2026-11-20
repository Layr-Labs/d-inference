import Foundation
import Darwin
@testable import MLXLLM

private enum StageCheckFailure: Error { case assertion(Int), expectedStageError }

func require(_ value: @autoclosure () -> Bool, line: Int = #line) throws {
    guard value() else { throw StageCheckFailure.assertion(line) }
}

func requireStageError<T>(_ body: () throws -> T) throws {
    do { _ = try body() }
    catch is Gemma4LayerStageError { return }
    throw StageCheckFailure.expectedStageError
}

/// No Module/MLXArray is constructed. Linking/typechecking the actual native
/// implementation is separate from invoking its constructor or forward path.
@main enum Gemma4StageConstructorCheck {
    static func main() throws {
        guard CommandLine.arguments.count == 3,
            CommandLine.arguments[1] == "check-metadata" else { Darwin.exit(64) }
        signal(SIGALRM) { _ in Darwin._exit(124) }; alarm(15)
        let checks = Gemma4LayerStagePolicyTests()
        try checks.allCutsKeepGlobalAttentionAndLocalCacheIndices()
        try checks.refusesInvalidRangesAndResponsibilities()
        try checks.rejectsCompactedOrUnsupportedOriginalGeometry()
        try checks.retainsMixedPrecisionAndSplitExpertEligibility()
        try checks.rankZeroAlwaysPreservesEveryResidualRow()
        try checks.onlyGlobalFinalLayerCanUseLastQuery()
        try checks.fullTrunkPolicyMatchesPreExtractionConditions()

        let url = URL(fileURLWithPath: CommandLine.arguments[2])
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? NSNumber,
            (1...1_048_576).contains(size.intValue) else { throw StageCheckFailure.assertion(#line) }
        let bytes = try Data(contentsOf: url)
        try require(bytes.count == size.intValue)
        let original = try JSONDecoder().decode(Gemma4Configuration.self, from: bytes)
        for cut in 1..<30 {
            let first = try Gemma4LayerStageLayout(originalConfiguration: original,
                rank: 0, sourceLayerRange: 0..<cut)
            let second = try Gemma4LayerStageLayout(originalConfiguration: original,
                rank: 1, sourceLayerRange: cut..<30)
            try require(first.globalLayerIndices + second.globalLayerIndices == Array(0..<30))
            try require(!first.ownsFinalOutput && second.ownsFinalOutput)
        }
        let result: [String: Any] = ["passed": true, "valueOnlyGroups": 7,
            "actualArtifactCuts": 29, "nativeModelConstructed": false, "payloadRead": false]
        let output = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
        try FileHandle.standardOutput.write(contentsOf: output + Data([10]))
        alarm(0)
    }
}
