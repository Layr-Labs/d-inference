import Foundation
import Testing

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

private final class WeightHasherResourceBundleAnchor {}

private let weightHasherResourceTestsEnabled: Bool = {
    guard let value = ProcessInfo.processInfo.environment["DARKBLOOM_RESOURCE_TESTS"] else {
        return false
    }
    return ["1", "true", "yes", "on"].contains(value.lowercased())
}()

@Suite(
    "Weight hasher memory (resource)",
    .enabled(
        if: weightHasherResourceTestsEnabled,
        "set DARKBLOOM_RESOURCE_TESTS=1 to run memory resource tests"))
struct WeightHasherMemoryTests {
    private static let fixtureSizeBytes: UInt64 = 192 * 1024 * 1024
    private static let maxAllowedRSSGrowthBytes: UInt64 = 64 * 1024 * 1024
    private static let timeout: TimeInterval = 60

    @Test("large-file hashing stays within the resident-memory budget")
    func largeFileHashingUsesBoundedCurrentRSS() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("weight-hasher-memory-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        try "{}".write(
            to: temporaryDirectory.appendingPathComponent("config.json"),
            atomically: true,
            encoding: .utf8)
        let shard = temporaryDirectory.appendingPathComponent("model.safetensors")
        FileManager.default.createFile(atPath: shard.path, contents: nil)
        let handle = try FileHandle(forWritingTo: shard)
        try handle.truncate(atOffset: Self.fixtureSizeBytes)
        try handle.close()

        let output = temporaryDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("weight-hasher-manifest-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: output) }

        let result = try Self.runHashProbe(snapshot: temporaryDirectory, output: output)
        #expect(
            result.terminationReason == .exit,
            "resource probe was terminated by a signal; output:\n\(result.output)")
        #expect(
            result.terminationStatus == 0,
            "resource probe exited with status \(result.terminationStatus); output:\n\(result.output)")
        #expect(
            result.currentRSSGrowthBytes < Self.maxAllowedRSSGrowthBytes,
            Comment(rawValue:
                "hashing a \(Self.fixtureSizeBytes)-byte shard in a fresh process must grow "
                    + "current RSS by less than \(Self.maxAllowedRSSGrowthBytes) bytes; observed "
                    + "\(result.currentRSSGrowthBytes) bytes"))
    }

    private static func runHashProbe(snapshot: URL, output: URL) throws -> ProbeResult {
        let process = Process()
        process.executableURL = try publishBinary()
        process.arguments = [
            "hash",
            snapshot.path,
            "--id", "resource-test/model",
            "--version", "resource-test",
            "--output", output.path,
        ]
        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        try process.run()
        let deadline = Date().addingTimeInterval(timeout)
        var maximumCurrentRSSBytes: UInt64 = 0
        var minimumCurrentRSSBytes = UInt64.max
        var measurementError: (any Error)?

        while process.isRunning {
            do {
                let residentBytes = try currentRSSBytes(
                    processID: process.processIdentifier)
                minimumCurrentRSSBytes = min(minimumCurrentRSSBytes, residentBytes)
                maximumCurrentRSSBytes = max(maximumCurrentRSSBytes, residentBytes)
            } catch {
                if process.isRunning {
                    measurementError = error
                }
            }

            if Date() >= deadline {
                process.terminate()
                let terminationDeadline = Date().addingTimeInterval(2)
                while process.isRunning, Date() < terminationDeadline {
                    Thread.sleep(forTimeInterval: 0.01)
                }
                if process.isRunning {
                    kill(process.processIdentifier, SIGKILL)
                }
                process.waitUntilExit()
                throw WeightHasherResourceTestError.timedOut(timeout)
            }
            Thread.sleep(forTimeInterval: 0.005)
        }

        process.waitUntilExit()
        let capturedOutput = String(
            decoding: outputPipe.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self)
        if maximumCurrentRSSBytes == 0, let measurementError {
            throw measurementError
        }
        guard minimumCurrentRSSBytes != UInt64.max, maximumCurrentRSSBytes > 0 else {
            throw WeightHasherResourceTestError.noRSSObservation
        }

        return ProbeResult(
            terminationReason: process.terminationReason,
            terminationStatus: process.terminationStatus,
            minimumCurrentRSSBytes: minimumCurrentRSSBytes,
            maximumCurrentRSSBytes: maximumCurrentRSSBytes,
            output: capturedOutput)
    }

    private static func publishBinary() throws -> URL {
        let anchor = Bundle(for: WeightHasherResourceBundleAnchor.self).bundleURL
        let productsDirectory = anchor.pathExtension == "xctest"
            ? anchor.deletingLastPathComponent()
            : anchor
        let binary = productsDirectory.appendingPathComponent("darkbloom-publish")
        guard FileManager.default.isExecutableFile(atPath: binary.path) else {
            throw WeightHasherResourceTestError.missingPublishBinary(binary)
        }
        return binary
    }

    private static func currentRSSBytes(processID: Int32) throws -> UInt64 {
        #if canImport(Darwin)
        var info = proc_taskinfo()
        let expectedSize = Int32(MemoryLayout<proc_taskinfo>.size)
        let actualSize = proc_pidinfo(
            processID,
            PROC_PIDTASKINFO,
            0,
            &info,
            expectedSize)
        guard actualSize == expectedSize else {
            throw WeightHasherResourceTestError.rssMeasurementFailed(errno)
        }
        return info.pti_resident_size
        #elseif canImport(Glibc)
        let statm = try String(
            contentsOfFile: "/proc/\(processID)/statm",
            encoding: .utf8)
        let fields = statm.split(whereSeparator: \.isWhitespace)
        guard fields.count > 1,
              let residentPages = UInt64(fields[1]),
              sysconf(Int32(_SC_PAGESIZE)) > 0
        else {
            throw WeightHasherResourceTestError.invalidProcStatm(statm)
        }
        return residentPages * UInt64(sysconf(Int32(_SC_PAGESIZE)))
        #else
        throw WeightHasherResourceTestError.currentRSSUnavailable
        #endif
    }
}

private struct ProbeResult {
    let terminationReason: Process.TerminationReason
    let terminationStatus: Int32
    let minimumCurrentRSSBytes: UInt64
    let maximumCurrentRSSBytes: UInt64

    var currentRSSGrowthBytes: UInt64 {
        maximumCurrentRSSBytes > minimumCurrentRSSBytes
            ? maximumCurrentRSSBytes - minimumCurrentRSSBytes
            : 0
    }
    let output: String
}

private enum WeightHasherResourceTestError: Error {
    case missingPublishBinary(URL)
    case timedOut(TimeInterval)
    case noRSSObservation
    case rssMeasurementFailed(Int32)
    case invalidProcStatm(String)
    case currentRSSUnavailable
}
