import Darwin
import Foundation
import SandboxCore
import SandboxRuntime
@testable import SandboxRuntimeLume
import XCTest

final class LumeInstalledCandidatePublicationTests: XCTestCase {
    func testPublishesInstalledEvidenceAndReplaysWithoutChangingReservationOrReadiness() async throws {
        let f = try await LumeQualificationFixture(); defer { f.remove() }
        let input = try collectAndClear(f)
        let runtime = LumeVirtualMachineRuntime(configuration: f.configuration)
        let checkpoint = try await runtime.publishInstalledCandidate(name: f.source.name, candidateID: f.candidateID,
            installationData: input.installation, cleanupData: input.cleanup)
        XCTAssertEqual(checkpoint.phase, .installedAwaitingQualification)
        XCTAssertEqual(checkpoint.source, f.source)
        XCTAssertEqual(checkpoint.candidateID, f.candidateID)
        let first = try Data(contentsOf: f.path(LumeInstalledCandidateCheckpoint.fileName))
        let replay = try await runtime.publishInstalledCandidate(name: f.source.name, candidateID: f.candidateID,
            installationData: input.installation, cleanupData: input.cleanup)
        XCTAssertEqual(checkpoint, replay)
        XCTAssertEqual(try Data(contentsOf: f.path(LumeInstalledCandidateCheckpoint.fileName)), first)
        XCTAssertEqual(try Data(contentsOf: f.path(LumeInstalledCandidateCheckpoint.reservationFileName)), input.reservation)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.path(SandboxGuestTemplateReceipt.fileName).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.vm.createStarted.path))
        // The newly written checkpoint is actually accepted by the consumer.
        let capability = try await f.issue()
        XCTAssertEqual(capability.checkpoint, checkpoint)
    }

    func testMatchingPartialPublicationCanComplete() async throws {
        let f = try await LumeQualificationFixture(); defer { f.remove() }
        let input = try collectAndClear(f)
        try input.installation.write(to: f.path(LumeInstalledCandidateCheckpoint.installationFileName))
        XCTAssertEqual(chmod(f.path(LumeInstalledCandidateCheckpoint.installationFileName).path, 0o600), 0)
        let runtime = LumeVirtualMachineRuntime(configuration: f.configuration)
        _ = try await runtime.publishInstalledCandidate(name: f.source.name, candidateID: f.candidateID,
            installationData: input.installation, cleanupData: input.cleanup)
        XCTAssertEqual(try Data(contentsOf: f.path(LumeInstalledCandidateCheckpoint.installationFileName)), input.installation)
    }

    func testIncompleteOrMixedEvidenceCannotWriteAnyInstalledFile() async throws {
        for mutation in ["installation", "cleanup", "attempt", "candidate", "disk", "resources", "duplicate"] {
            let f = try await LumeQualificationFixture(); defer { f.remove() }
            let input = try collectAndClear(f)
            var installation = input.installation
            var cleanup = try object(input.cleanup)
            var candidate = f.candidateID
            switch mutation {
            case "installation": installation = try changing(installation) { $0["installerExitCode"] = 70 }
            case "cleanup": cleanup["fullyDetached"] = false
            case "attempt": cleanup["bootstrapAttemptID"] = UUID().uuidString
            case "candidate": candidate = UUID()
            case "disk":
                let file = try FileHandle(forWritingTo: f.path("disk.img"))
                try file.write(contentsOf: Data([1])); try file.close()
            case "resources":
                let path = f.path(LumeInstalledCandidateCheckpoint.reservationFileName)
                let changed = try changing(Data(contentsOf: path)) { value in
                    var resources = value["resources"] as! [String: Any]
                    resources["cpuCount"] = 8; value["resources"] = resources
                }
                try changed.write(to: path)
            default:
                let text = String(decoding: installation, as: UTF8.self)
                installation = Data(("{\"schemaVersion\":2," + text.dropFirst()).utf8)
            }
            cleanup["installationReceiptSHA256"] = LumeInstalledCandidateStore.digest(installation)
            let cleanupData = try JSONSerialization.data(withJSONObject: cleanup, options: [.sortedKeys])
            let expectedReservation = try Data(contentsOf: f.path(LumeInstalledCandidateCheckpoint.reservationFileName))
            let runtime = LumeVirtualMachineRuntime(configuration: f.configuration)
            await rejects { _ = try await runtime.publishInstalledCandidate(name: f.source.name, candidateID: candidate,
                installationData: installation, cleanupData: cleanupData) }
            for name in installedNames { XCTAssertFalse(FileManager.default.fileExists(atPath: f.path(name).path), mutation) }
            XCTAssertEqual(try Data(contentsOf: f.path(LumeInstalledCandidateCheckpoint.reservationFileName)), expectedReservation)
        }
    }

    func testConflictingLinkedOrSpecialExistingFileIsNeverOverwritten() async throws {
        for mutation in ["different", "public", "symlink", "hardlink", "fifo"] {
            let f = try await LumeQualificationFixture(); defer { f.remove() }
            let input = try collectAndClear(f)
            let path = f.path(LumeInstalledCandidateCheckpoint.cleanupFileName)
            switch mutation {
            case "fifo": XCTAssertEqual(mkfifo(path.path, 0o600), 0)
            case "symlink": try FileManager.default.createSymbolicLink(at: path, withDestinationURL: f.path("disk.img"))
            default:
                try (mutation == "different" ? Data("{}".utf8) : input.cleanup).write(to: path)
                XCTAssertEqual(chmod(path.path, mutation == "public" ? 0o644 : 0o600), 0)
                if mutation == "hardlink" { XCTAssertEqual(link(path.path, f.path("alias").path), 0) }
            }
            var before = stat(); XCTAssertEqual(lstat(path.path, &before), 0)
            let runtime = LumeVirtualMachineRuntime(configuration: f.configuration)
            await rejects { _ = try await runtime.publishInstalledCandidate(name: f.source.name, candidateID: f.candidateID,
                installationData: input.installation, cleanupData: input.cleanup) }
            var after = stat(); XCTAssertEqual(lstat(path.path, &after), 0)
            XCTAssertEqual(before.st_ino, after.st_ino)
            XCTAssertFalse(FileManager.default.fileExists(atPath: f.path(LumeInstalledCandidateCheckpoint.fileName).path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: f.path(LumeInstalledCandidateCheckpoint.installationFileName).path))
        }
    }

    func testRunningSourceAndConsumerRuntimeCannotAdvanceBase() async throws {
        let f = try await LumeQualificationFixture(); defer { f.remove() }
        let input = try collectAndClear(f)
        let fenced = LumeVirtualMachineRuntime(configuration: f.configuration, capacityArbiter: f.arbiter)
        await rejects { _ = try await fenced.publishInstalledCandidate(name: f.source.name, candidateID: f.candidateID,
            installationData: input.installation, cleanupData: input.cleanup) }
        try Data("running\n".utf8).write(to: f.vm.state)
        let runtime = LumeVirtualMachineRuntime(configuration: f.configuration)
        await rejects { _ = try await runtime.publishInstalledCandidate(name: f.source.name, candidateID: f.candidateID,
            installationData: input.installation, cleanupData: input.cleanup) }
        for name in installedNames { XCTAssertFalse(FileManager.default.fileExists(atPath: f.path(name).path)) }
    }

    func testEvidenceWriterCannotTargetReservationOrArbitraryPaths() async throws {
        let f = try await LumeQualificationFixture(); defer { f.remove() }
        let directory = open(f.vm.virtualMachineDirectory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(directory, 0); defer { close(directory) }
        for name in ["../outside", "disk.img", LumeInstalledCandidateCheckpoint.reservationFileName] {
            XCTAssertThrowsError(try LumeCandidateEvidencePublication.publish(Data("{}".utf8), name: name, directory: directory))
        }
    }

    private let installedNames = [LumeInstalledCandidateCheckpoint.installationFileName,
        LumeInstalledCandidateCheckpoint.cleanupFileName, LumeInstalledCandidateCheckpoint.fileName]
    private func collectAndClear(_ f: LumeQualificationFixture) throws -> (installation: Data, cleanup: Data, reservation: Data) {
        let installation = try Data(contentsOf: f.path(LumeInstalledCandidateCheckpoint.installationFileName))
        let cleanup = try Data(contentsOf: f.path(LumeInstalledCandidateCheckpoint.cleanupFileName))
        let reservation = try Data(contentsOf: f.path(LumeInstalledCandidateCheckpoint.reservationFileName))
        for name in installedNames { try FileManager.default.removeItem(at: f.path(name)) }
        return (installation, cleanup, reservation)
    }
    private func object(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
    private func changing(_ data: Data, _ change: (inout [String: Any]) -> Void) throws -> Data {
        var value = try object(data); change(&value)
        return try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    }
    private func rejects(_ body: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
        do { try await body(); XCTFail("invalid installed-candidate publication accepted", file: file, line: line) }
        catch {}
    }
}
