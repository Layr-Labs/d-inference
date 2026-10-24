import Darwin
import Foundation
import XCTest
@testable import DarkbloomClusterRuntime

final class QwenBatchDiagnosticsTests: XCTestCase {
    private func temporary() throws -> URL {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("qwen-batch-diagnostics-\(UUID())")
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try FileManager.default.removeItem(at: path) }
        return path
    }

    private func context(ordinal: Int = 0, id: UUID = UUID()) -> QwenBatchRowCapture.Context {
        .init(batchOrdinal: 1, step: ordinal + 2, slot: 1, row: 1, decodeWidth: 2,
            phase: "decode", requestID: id, requestFingerprint: String(repeating: "a", count: 64),
            promptTokens: [11, 12], priorSelectedTokens: Array(repeating: 3, count: ordinal), selectedToken: 2)
    }

    func testSummaryMeasuresWidthsAndCreditsWithoutRequestContent() {
        var summary = QwenBatchStepSummary()
        summary.record(width: 0, pending: 2, answered: 0, prefill: false, joining: 1, leaving: 0)
        summary.record(width: 1, pending: 2, answered: 1, prefill: true, joining: 0, leaving: 0)
        summary.record(width: 4, pending: 4, answered: 4, prefill: false, joining: 0, leaving: 1)
        XCTAssertEqual(summary.decodeWidths, [1, 1, 0, 0, 1, 0, 0, 0, 0])
        XCTAssertEqual(summary.pendingCreditObservations, 8); XCTAssertEqual(summary.answeredCredits, 5)
        XCTAssertEqual(summary.maximumPendingCredits, 4)
        XCTAssertFalse(summary.line.contains("request")); XCTAssertFalse(summary.line.contains("token"))
        XCTAssertFalse(summary.line.contains("sha")); XCTAssertTrue(summary.line.contains("steps=3"))
    }

    func testCapturePreservesNativeBytesAndBindsPriorHistory() throws {
        let root = try temporary(), id = UUID()
        let capture = try QwenBatchRowCapture(path: root.path)
        let bytes = Data([0, 0, 0, 128, 128, 63, 0, 64]) // raw bf16, including signed zero
        try capture.capture(context(id: id), shape: [1, 4], dtype: "bfloat16") { bytes }
        try capture.capture(context(ordinal: 1, id: id), shape: [1, 4], dtype: "bfloat16") { bytes }
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        let records = try files.filter { $0.pathExtension == "json" }.map {
            try JSONDecoder().decode(QwenBatchRowCapture.Record.self, from: Data(contentsOf: $0))
        }.sorted { $0.outputOrdinal < $1.outputOrdinal }
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records[0].priorHistorySHA256, QwenLayerStageBoundary.tokenHash([11, 12]))
        XCTAssertEqual(records[1].priorHistorySHA256, QwenLayerStageBoundary.tokenHash([11, 12, 3]))
        XCTAssertEqual(records[0].promptTokensSHA256, records[1].promptTokensSHA256)
        for record in records {
            XCTAssertEqual(record.requestID, id); XCTAssertEqual(record.logicalBytesSHA256, sha256(bytes))
            let file = root.appendingPathComponent(record.bytesFile)
            XCTAssertEqual(try Data(contentsOf: file), bytes)
        }
        for file in files {
            let mode = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)
            XCTAssertEqual(mode.intValue & 0o777, 0o600)
        }
        XCTAssertThrowsError(try capture.capture(context(id: id), shape: [1, 4], dtype: "bfloat16") { bytes })
    }

    func testUnselectedOrdinalsNeverReadBytesAndInvalidGeometryRefuses() throws {
        let root = try temporary(), capture = try QwenBatchRowCapture(path: root.path)
        XCTAssertEqual(QwenBatchRowCapture.ordinals, [0, 1, 30, 37, 78, 88])
        var read = false
        try capture.capture(context(ordinal: 2), shape: [1, 4], dtype: "bfloat16") { read = true; return Data() }
        XCTAssertFalse(read)
        XCTAssertThrowsError(try capture.capture(context(), shape: [2, 4], dtype: "bfloat16") { Data() })
        XCTAssertThrowsError(try capture.capture(context(), shape: [1, 4], dtype: "int32") { Data() })
        XCTAssertThrowsError(try capture.capture(context(), shape: [1, 4], dtype: "bfloat16") { Data([0]) })
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).count, 0)
    }

    func testDirectoryRefusesSymlinkSharedPermissionsConcurrentWriterAndExhaustedBudget() throws {
        let root = try temporary(), privatePath = root.appendingPathComponent("private")
        var first: QwenBatchRowCapture? = try .init(path: privatePath.path)
        XCTAssertNotNil(first)
        XCTAssertThrowsError(try QwenBatchRowCapture(path: privatePath.path))
        first = nil
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: privatePath)
        XCTAssertThrowsError(try QwenBatchRowCapture(path: link.path))
        try FileManager.default.setAttributes([.posixPermissions: 0o750], ofItemAtPath: privatePath.path)
        XCTAssertThrowsError(try QwenBatchRowCapture(path: privatePath.path))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: privatePath.path)
        for index in 0..<QwenBatchRowCapture.maximumCaptures {
            try Data().write(to: privatePath.appendingPathComponent("existing-\(index).bin"))
        }
        XCTAssertThrowsError(try QwenBatchRowCapture(path: privatePath.path))
    }

    func testDiagnosticEnvironmentRequiresExplicitQualificationPermission() throws {
        for name in [QwenBatchRowCapture.environmentName, QwenBatchRowCapture.traceEnvironmentName] {
            XCTAssertThrowsError(try QwenResidentQualificationSwitches.refused.admit(environment: [name: "1"]))
            XCTAssertNoThrow(try QwenResidentQualificationSwitches.permittedByExplicitFlag.admit(environment: [name: "1"]))
        }
        XCTAssertNil(try QwenBatchRowCapture.fromEnvironment(environment: [:]))
        XCTAssertFalse(try QwenBatchRowCapture.traceRequested(environment: [:]))
        XCTAssertThrowsError(try QwenBatchRowCapture.traceRequested(environment: [QwenBatchRowCapture.traceEnvironmentName: "yes"]))
    }
}
