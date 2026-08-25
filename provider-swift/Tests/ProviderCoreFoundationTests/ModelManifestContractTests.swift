import XCTest
@testable import ProviderCoreFoundation

final class ModelManifestContractTests: XCTestCase {
    func testEncodedByteBoundary() throws {
        XCTAssertNoThrow(
            try ModelManifestContract.validateEncodedByteCount(
                ModelManifestContract.maximumEncodedBytes))
        XCTAssertThrowsError(
            try ModelManifestContract.validateEncodedByteCount(
                ModelManifestContract.maximumEncodedBytes + 1))
    }

    func testRejectsFileCountOverLimit() {
        let manifest = makeManifest(
            fileCount: ModelManifestContract.maximumFileCount + 1)
        XCTAssertThrowsError(try ModelManifestContract.validate(manifest)) { error in
            XCTAssertTrue(error.localizedDescription.contains("file_count"))
        }
    }

    func testRejectsNegativeFileSize() {
        let manifest = makeManifest(
            totalSizeBytes: 0,
            files: [
                ManifestFile(
                    path: "config.json",
                    sizeBytes: -1,
                    sha256: String(repeating: "b", count: 64),
                    role: "config")
            ])
        XCTAssertThrowsError(try ModelManifestContract.validate(manifest)) { error in
            XCTAssertTrue(error.localizedDescription.contains("nonnegative"))
        }
    }

    func testRejectsAggregateSizeOverflow() {
        let manifest = makeManifest(
            totalSizeBytes: Int64.max,
            fileCount: 2,
            files: [
                ManifestFile(
                    path: "a.bin",
                    sizeBytes: Int64.max,
                    sha256: String(repeating: "b", count: 64),
                    role: "weight"),
                ManifestFile(
                    path: "b.bin",
                    sizeBytes: 1,
                    sha256: String(repeating: "c", count: 64),
                    role: "weight"),
            ])
        XCTAssertThrowsError(try ModelManifestContract.validate(manifest)) { error in
            XCTAssertTrue(error.localizedDescription.contains("overflow"))
        }
    }

    private func makeManifest(
        totalSizeBytes: Int64 = 5,
        fileCount: Int = 1,
        files: [ManifestFile] = [
            ManifestFile(
                path: "config.json",
                sizeBytes: 5,
                sha256: String(repeating: "b", count: 64),
                role: "config")
        ]
    ) -> ModelManifest {
        ModelManifest(
            schemaVersion: 1,
            modelID: "contract-model",
            version: "v1",
            r2Prefix: "v2/contract-model/v1",
            aggregateSHA256: String(repeating: "a", count: 64),
            totalSizeBytes: totalSizeBytes,
            fileCount: fileCount,
            files: files,
            createdAt: Date(timeIntervalSince1970: 0))
    }
}
