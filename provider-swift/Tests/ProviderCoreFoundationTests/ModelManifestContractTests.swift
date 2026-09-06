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

    func testRejectsExactDuplicatePaths() {
        let manifest = makeManifest(paths: [
            "weights/model.safetensors",
            "config.json",
            "weights/model.safetensors",
        ])
        XCTAssertThrowsError(try ModelManifestContract.validate(manifest)) { error in
            guard case ModelManifestContract.ValidationError.duplicateFilePath(let path) = error else {
                return XCTFail("expected duplicateFilePath, got \(error)")
            }
            XCTAssertEqual(path, "weights/model.safetensors")
        }
    }

    func testRejectsCaseInsensitiveDuplicatePaths() {
        for duplicatePath in [
            "weights/MODEL.safetensors",
            "WEIGHTS/model.safetensors",
            "WEIGHTS/MODEL.SAFETENSORS",
        ] {
            let manifest = makeManifest(paths: ["weights/model.safetensors", duplicatePath])
            XCTAssertThrowsError(try ModelManifestContract.validate(manifest), duplicatePath) { error in
                guard case ModelManifestContract.ValidationError.duplicateFilePath(let path) = error else {
                    return XCTFail("expected duplicateFilePath for \(duplicatePath), got \(error)")
                }
                XCTAssertEqual(path, duplicatePath)
            }
        }
    }

    func testAcceptsDistinctPaths() throws {
        let manifest = makeManifest(paths: [
            "Config.json",
            "weights/model.safetensors",
            "weights/model-00001.safetensors",
            "vision/MODEL.safetensors",
        ])
        XCTAssertNoThrow(try ModelManifestContract.validate(manifest))
        XCTAssertEqual(try ModelManifestContract.checkedTotalSize(manifest.files), 20)
    }

    private func makeManifest(paths: [String]) -> ModelManifest {
        makeManifest(
            totalSizeBytes: Int64(paths.count) * 5,
            fileCount: paths.count,
            files: paths.map { path in
                ManifestFile(
                    path: path,
                    sizeBytes: 5,
                    sha256: String(repeating: "b", count: 64),
                    role: "weight")
            })
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
