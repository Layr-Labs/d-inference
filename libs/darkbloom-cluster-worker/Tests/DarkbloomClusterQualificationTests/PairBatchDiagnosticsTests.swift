import Foundation
import XCTest
@testable import DarkbloomClusterQualification

final class PairBatchDiagnosticsTests: XCTestCase {
    private func configuration(localRank: Int) throws -> PairConfiguration {
        let request = try QualificationRequest(requestID: UUID(), promptTokenIDs: Array(1...40), chunkSize: 16,
            outputCount: 128, stopTokenIDs: [], promptSource: .init(kind: "tokenIDs", description: "test"))
        let side = PairSide(modelDirectory: "/tmp/model", workerPath: "/tmp/worker",
            rdmaDevice: "rdma_en5", scratchDirectory: "/tmp/scratch")
        return try .init(request: request, stageCut: 8, local: side, remote: side,
            remoteTransport: ["/bin/sh", "-c"], coordinator: "10.77.0.1:47000", recording: false, progressTimeoutMilliseconds: 60_000,
            localRank: localRank)
    }

    func testOnlyRankOneReceivesPrivateDirectoryInEitherRankOrder() throws {
        for localRank in 0...1 {
            var c = try configuration(localRank: localRank)
            c.batchLanes = 4; c.batchTrace = true; c.batchLogitDirectory = "/tmp/qwen-private-rows"
            try c.validate()
            for rank in 0...1 {
                let script = c.launchScript(rank, artifactSHA256: String(repeating: "a", count: 64),
                    configurationSHA256: String(repeating: "b", count: 64), workerSHA256: String(repeating: "c", count: 64))
                XCTAssertTrue(script.contains("DARKBLOOM_CLUSTER_BATCH_TRACE='1'"))
                XCTAssertEqual(script.contains("DARKBLOOM_CLUSTER_BATCH_LOGIT_DIRECTORY="), rank == 1)
                XCTAssertTrue(script.contains("--qualification-switches"))
            }
        }
    }

    func testGPTOSSBatchIsolationDoesNotEnableQwenDiagnostics() throws {
        let request = try QualificationRequest(requestID: UUID(), promptTokenIDs: Array(1...40), chunkSize: 16,
            outputCount: 128, stopTokenIDs: [], promptSource: .init(kind: "tokenIDs", description: "test"),
            modelID: "registered_gpt_oss_20b")
        let side = PairSide(modelDirectory: "/tmp/model", workerPath: "/tmp/worker",
            rdmaDevice: "rdma_en5", scratchDirectory: "/tmp/scratch")
        var c = try PairConfiguration(request: request, stageCut: 6, local: side, remote: side,
            remoteTransport: ["/bin/sh", "-c"], coordinator: "10.77.0.1:47000", recording: false,
            progressTimeoutMilliseconds: 60_000)
        c.batchLanes = 4; try c.validate(); XCTAssertTrue(c.lanesRetireAlone)
        c.batchTrace = true; XCTAssertThrowsError(try c.validate())
        c.batchTrace = false; c.batchLogitDirectory = "/tmp/private"; XCTAssertThrowsError(try c.validate())
    }

    func testDiagnosticsAreAbsentByDefaultAndRefuseWrongModeLaneCountOrRecording() throws {
        var c = try configuration(localRank: 0)
        var script = c.launchScript(1, artifactSHA256: "a", configurationSHA256: "b", workerSHA256: "c")
        XCTAssertFalse(script.contains("DARKBLOOM_CLUSTER_BATCH_TRACE")); XCTAssertFalse(script.contains("DARKBLOOM_CLUSTER_BATCH_LOGIT_DIRECTORY"))
        c.batchTrace = true; XCTAssertThrowsError(try c.validate())
        c.batchLanes = 2; XCTAssertNoThrow(try c.validate())
        c.generationMode = PairConfiguration.pipelineMTPMode; XCTAssertThrowsError(try c.validate())
        c.generationMode = PairConfiguration.pipelineMode; c.recording = true; XCTAssertThrowsError(try c.validate())
        c.recording = false; c.batchLogitDirectory = "relative"; XCTAssertThrowsError(try c.validate())
        c.batchLogitDirectory = "/tmp/private"; try c.validate()
        script = c.launchScript(1, artifactSHA256: "a", configurationSHA256: "b", workerSHA256: "c")
        XCTAssertTrue(script.contains("DARKBLOOM_CLUSTER_BATCH_LOGIT_DIRECTORY='/tmp/private'"))
    }
}
