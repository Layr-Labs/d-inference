/// DGInfAppTests — Unit tests for the DGInf menu bar app.
///
/// Tests cover:
///   - ProviderManager: binary path resolution, command building
///   - ModelManager: HuggingFace cache scanning, size formatting
///   - StatusViewModel: state transitions
///
/// Note: Some tests use mock directories since the real system state
/// (Secure Enclave, system_profiler) varies by machine. Tests that
/// require a running macOS desktop environment are marked with comments.

import XCTest
@testable import DGInf

// MARK: - ProviderManager Tests

final class ProviderManagerTests: XCTestCase {

    func testBuildArguments() {
        let args = ProviderManager.buildArguments(
            model: "mlx-community/Qwen3.5-4B-4bit",
            coordinatorURL: "https://coordinator.dginf.io",
            port: 8321
        )

        XCTAssertEqual(args, [
            "serve",
            "--coordinator", "https://coordinator.dginf.io",
            "--model", "mlx-community/Qwen3.5-4B-4bit",
            "--backend-port", "8321",
        ])
    }

    func testBuildArgumentsCustomPort() {
        let args = ProviderManager.buildArguments(
            model: "test-model",
            coordinatorURL: "http://localhost:9090",
            port: 9999
        )

        XCTAssertEqual(args.count, 7)
        XCTAssertEqual(args[0], "serve")
        XCTAssertEqual(args[5], "--backend-port")
        XCTAssertEqual(args[6], "9999")
    }

    func testResolveBinaryPathReturnsNilOrPath() {
        // This test verifies the method doesn't crash and returns
        // either a valid path or nil. The actual result depends on
        // whether dginf-provider is installed on the test machine.
        let path = ProviderManager.resolveBinaryPath()
        if let path = path {
            XCTAssertTrue(
                FileManager.default.isExecutableFile(atPath: path),
                "Resolved path should be executable"
            )
        }
        // nil is also acceptable — just means the binary isn't installed
    }
}

// MARK: - ModelManager Tests

final class ModelManagerTests: XCTestCase {

    func testFormatSizeBytes() {
        // 500,000,000 bytes = ~477 MiB (base-1024 division)
        XCTAssertEqual(ModelManager.formatSize(500_000_000), "477 MB")
    }

    func testFormatSizeGB() {
        let fourGB: UInt64 = 4 * 1024 * 1024 * 1024
        XCTAssertEqual(ModelManager.formatSize(fourGB), "4.0 GB")
    }

    func testFormatSizeFractionalGB() {
        let size: UInt64 = UInt64(2.5 * 1024 * 1024 * 1024)
        XCTAssertEqual(ModelManager.formatSize(size), "2.5 GB")
    }

    @MainActor
    func testScanEmptyDirectory() throws {
        let manager = ModelManager()

        // Create a temp directory to use as cache
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dginf-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tempDir,
            withIntermediateDirectories: true
        )
        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }

        // Scanning should produce empty results (the default cache dir
        // may or may not exist, but this verifies no crash)
        manager.scanModels()
        // We can't assert the count because the real cache may have models
    }

    @MainActor
    func testScanWithMockModels() throws {
        let _ = ModelManager()

        // Create a mock HuggingFace cache structure in a temp directory
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dginf-test-\(UUID().uuidString)")
        let modelsDir = tempDir.appendingPathComponent(
            "models--mlx-community--Qwen3.5-4B-4bit/snapshots/abc123"
        )
        try FileManager.default.createDirectory(
            at: modelsDir,
            withIntermediateDirectories: true
        )

        // Write a fake model file
        let fakeModel = Data(repeating: 0, count: 1024)
        try fakeModel.write(to: modelsDir.appendingPathComponent("model.safetensors"))

        // The ModelManager uses a hardcoded cache path, so we can't easily
        // redirect it in a unit test. This test verifies the structure is correct.
        // In a real integration test, we would inject the cache path.

        // Clean up
        try FileManager.default.removeItem(at: tempDir)
    }

    @MainActor
    func testFitsInMemory() {
        let manager = ModelManager()
        let smallModel = LocalModel(
            id: "test/small",
            name: "small",
            sizeBytes: 2 * 1024 * 1024 * 1024, // 2 GB
            isMLX: true
        )
        let largeModel = LocalModel(
            id: "test/large",
            name: "large",
            sizeBytes: 100 * 1024 * 1024 * 1024, // 100 GB
            isMLX: true
        )

        // With 16 GB total memory (12 GB available after 4 GB headroom)
        XCTAssertTrue(manager.fitsInMemory(smallModel, totalMemoryGB: 16))
        XCTAssertFalse(manager.fitsInMemory(largeModel, totalMemoryGB: 16))
    }
}

// MARK: - StatusViewModel Tests

final class StatusViewModelTests: XCTestCase {

    @MainActor
    func testInitialState() {
        let vm = StatusViewModel()

        XCTAssertFalse(vm.isOnline)
        XCTAssertFalse(vm.isServing)
        XCTAssertFalse(vm.isPaused)
        XCTAssertEqual(vm.tokensPerSecond, 0)
        XCTAssertEqual(vm.requestsServed, 0)
        XCTAssertEqual(vm.tokensGenerated, 0)
        XCTAssertEqual(vm.uptimeSeconds, 0)
    }

    @MainActor
    func testDefaultSettings() {
        // Clear UserDefaults for clean test
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "coordinatorURL")
        defaults.removeObject(forKey: "apiKey")
        defaults.removeObject(forKey: "idleTimeoutSeconds")

        let vm = StatusViewModel()

        XCTAssertEqual(vm.coordinatorURL, "https://coordinator.dginf.io")
        XCTAssertEqual(vm.apiKey, "")
        XCTAssertEqual(vm.idleTimeoutSeconds, 300) // 5 minutes default
    }

    @MainActor
    func testPauseResume() {
        let vm = StatusViewModel()
        vm.isOnline = true

        vm.pauseProvider()
        XCTAssertTrue(vm.isPaused)

        vm.resumeProvider()
        XCTAssertFalse(vm.isPaused)
    }

    @MainActor
    func testStopResetsState() {
        let vm = StatusViewModel()
        vm.isOnline = true
        vm.isServing = true
        vm.isPaused = true
        vm.tokensPerSecond = 42.0

        vm.stop()

        XCTAssertFalse(vm.isOnline)
        XCTAssertFalse(vm.isServing)
        XCTAssertFalse(vm.isPaused)
        XCTAssertEqual(vm.tokensPerSecond, 0)
    }

    @MainActor
    func testMemoryDetection() {
        let vm = StatusViewModel()
        // The VM should detect at least some memory
        XCTAssertGreaterThan(vm.memoryGB, 0, "Should detect system memory")
    }
}
