import DarkbloomFanCore
import DarkbloomFanProtocol
import DarkbloomFanService
import Foundation
import Testing

#if canImport(Darwin)
import Darwin
#endif

@testable import darkbloom

@Suite("Fan service install steps")
struct FanServiceInstallStepTests {
    // MARK: bundle checks

    @Test("the bundled helper is Contents/Helpers inside Darkbloom.app")
    func bundledHelperLocation() throws {
        let fixture = try FanServiceFixture()
        defer { fixture.remove() }

        let helper = try fixture.manager().bundledHelperURL()

        #expect(helper.path == fixture.bundledHelper.path)
        let codesign = fixture.launchd.codesignCalls
        #expect(codesign.count == 2)
        #expect(codesign.first == [
            "--verify", "--deep", "--strict", "--verbose=2",
            "-R=" + FanCodeRequirements.requirement(
                identifier: FanIPC.providerIdentifier, teamID: FanIPC.teamID),
            fixture.app.path,
        ])
        #expect(codesign.last == [
            "--verify", "--strict", "--verbose=2",
            "-R=" + FanCodeRequirements.helperRequirement(),
            fixture.bundledHelper.path,
        ])
    }

    @Test("a MacOS folder outside an .app bundle is not a bundled install")
    func bundledHelperNeedsAppExtension() throws {
        let fixture = try FanServiceFixture()
        defer { fixture.remove() }
        let executable = fixture.root.appendingPathComponent("Darkbloom/Contents/MacOS/darkbloom")
        let manager = fixture.manager(host: fixture.host(executableURL: executable))

        let error = fanManagerError { _ = try manager.bundledHelperURL() }

        guard case .helperNotBundled = error else {
            Issue.record("expected helperNotBundled, got \(String(describing: error))")
            return
        }
        #expect(fixture.launchd.calls.isEmpty)
    }

    @Test("an outer app signature failure names Darkbloom.app")
    func bundledAppSignatureFails() throws {
        let fixture = try FanServiceFixture()
        defer { fixture.remove() }
        fixture.launchd.queue("codesign", failed(1, "a sealed resource is missing or invalid"))

        let error = fanManagerError { _ = try fixture.manager().bundledHelperURL() }

        guard case .signatureFailed(let detail) = error else {
            Issue.record("expected signatureFailed, got \(String(describing: error))")
            return
        }
        #expect(detail == "outer Darkbloom.app: a sealed resource is missing or invalid")
        #expect(error?.description == "fan helper signature verification failed: outer Darkbloom.app: a sealed resource is missing or invalid")
    }

    @Test("the fan capability marker and executable string are both required")
    func bundledAppNeedsCapability() throws {
        let markerValue = try FanServiceFixture()
        defer { markerValue.remove() }
        try Data("0\n".utf8).write(to: markerValue.marker)

        let markerMissing = try FanServiceFixture()
        defer { markerMissing.remove() }
        try FileManager.default.removeItem(at: markerMissing.marker)

        let markerIsFolder = try FanServiceFixture()
        defer { markerIsFolder.remove() }
        try FileManager.default.removeItem(at: markerIsFolder.marker)
        try FileManager.default.createDirectory(at: markerIsFolder.marker, withIntermediateDirectories: true)

        let oldBinary = try FanServiceFixture()
        defer { oldBinary.remove() }
        try Data("binary without the capability".utf8).write(to: oldBinary.executable)

        for fixture in [markerValue, markerMissing, markerIsFolder, oldBinary] {
            let error = fanManagerError { _ = try fixture.manager().bundledHelperURL() }
            guard case .unsafeFile(let detail) = error else {
                Issue.record("expected unsafeFile, got \(String(describing: error))")
                continue
            }
            #expect(detail == "Darkbloom.app fan capability marker is missing or invalid")
        }
    }

    @Test("the real executable path resolves to an existing file")
    func currentExecutableResolves() throws {
        let manager = FanServiceManager(paths: .production, environment: [:])

        let url = try manager.currentExecutableURL()

        #expect(url.path.hasPrefix("/"))
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(!url.path.contains("/./"))
    }

    // MARK: file checks

    @Test("only regular files with an execute bit pass the executable check")
    func regularExecutableCheck() throws {
        let fixture = try FanServiceFixture()
        defer { fixture.remove() }
        let manager = fixture.manager()
        let plain = fixture.root.appendingPathComponent("plain")
        try Data("x".utf8).write(to: plain)
        try setPermissions(0o644, plain)
        let link = fixture.root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.bundledHelper)
        let missing = fixture.root.appendingPathComponent("missing")

        try manager.verifyRegularExecutable(fixture.bundledHelper)
        for url in [plain, link, missing, fixture.root] {
            let error = fanManagerError { try manager.verifyRegularExecutable(url) }
            guard case .unsafeFile(let detail) = error else {
                Issue.record("expected unsafeFile for \(url.path), got \(String(describing: error))")
                continue
            }
            #expect(detail == "fan helper is not a regular executable: \(url.path)")
        }
    }

    @Test("a rejected helper signature carries the codesign output")
    func helperSignatureFailure() throws {
        let fixture = try FanServiceFixture()
        defer { fixture.remove() }
        fixture.launchd.queue("codesign", failed(3, "test-requirement: code failed to satisfy specified code requirement(s)"))

        let error = fanManagerError { try fixture.manager().verifyHelperSignature(fixture.bundledHelper) }

        guard case .signatureFailed(let detail) = error else {
            Issue.record("expected signatureFailed, got \(String(describing: error))")
            return
        }
        #expect(detail == "test-requirement: code failed to satisfy specified code requirement(s)")
    }

    @Test("ensureRootDirectory creates a missing tree with mode 755")
    func ensureRootDirectoryCreates() throws {
        let fixture = try FanServiceFixture()
        defer { fixture.remove() }
        let directory = fixture.root.appendingPathComponent("a/b/c")

        try fixture.manager().ensureRootDirectory(directory)

        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
        #expect(try filePermissions(directory) == 0o755)
    }

    @Test("ensureRootDirectory refuses files, symlinks and paths below a file")
    func ensureRootDirectoryRefusesUnsafePaths() throws {
        let fixture = try FanServiceFixture()
        defer { fixture.remove() }
        let manager = fixture.manager()
        let file = fixture.root.appendingPathComponent("file")
        try Data().write(to: file)
        let link = fixture.root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.app)

        for url in [file, link] {
            let error = fanManagerError { try manager.ensureRootDirectory(url) }
            guard case .unsafeFile(let detail) = error else {
                Issue.record("expected unsafeFile, got \(String(describing: error))")
                continue
            }
            #expect(detail == "privileged path is not a directory: \(url.path)")
        }

        let below = file.appendingPathComponent("child")
        let error = fanManagerError { try manager.ensureRootDirectory(below) }
        guard case .unsafeFile(let detail) = error else {
            Issue.record("expected unsafeFile, got \(String(describing: error))")
            return
        }
        #expect(detail == "could not inspect directory \(below.path) (errno \(ENOTDIR))")
    }

    @Test(
        "with root ownership on, a non-root user cannot secure the directory",
        .enabled(if: getuid() != 0)
    )
    func ensureRootDirectoryNeedsRootOwnership() throws {
        let fixture = try FanServiceFixture()
        defer { fixture.remove() }
        var host = fixture.host()
        host.requiresRootOwnership = true
        let directory = fixture.root.appendingPathComponent("owned")

        let error = fanManagerError {
            try fixture.manager(host: host).ensureRootDirectory(directory)
        }

        guard case .unsafeFile(let detail) = error else {
            Issue.record("expected unsafeFile, got \(String(describing: error))")
            return
        }
        #expect(detail == "could not secure directory \(directory.path) (errno \(EPERM))")
    }

    // MARK: helper install

    @Test("installHelper copies the helper atomically with mode 755")
    func installHelperCopies() throws {
        let fixture = try FanServiceFixture()
        defer { fixture.remove() }
        let large = Data((0..<200_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        try large.write(to: fixture.bundledHelper)
        try setPermissions(0o755, fixture.bundledHelper)

        try fixture.manager().installHelper(from: fixture.bundledHelper)

        #expect(try Data(contentsOf: fixture.paths.helper) == large)
        #expect(try filePermissions(fixture.paths.helper) == 0o755)
        #expect(fixture.launchd.codesignCalls.count == 4)
        let names = try FileManager.default.contentsOfDirectory(
            atPath: fixture.paths.helper.deletingLastPathComponent().path)
        #expect(names == [fixture.paths.helper.lastPathComponent])
    }

    @Test("installHelper refuses an empty helper and a symlinked helper")
    func installHelperRefusesUnsafeSource() throws {
        let fixture = try FanServiceFixture()
        defer { fixture.remove() }
        let manager = fixture.manager()
        let empty = fixture.root.appendingPathComponent("empty-helper")
        try Data().write(to: empty)
        let link = fixture.root.appendingPathComponent("linked-helper")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.bundledHelper)

        let emptyError = fanManagerError { try manager.installHelper(from: empty) }
        let linkError = fanManagerError { try manager.installHelper(from: link) }

        guard case .unsafeFile(let emptyDetail) = emptyError,
              case .unsafeFile(let linkDetail) = linkError
        else {
            Issue.record("expected unsafeFile, got \(String(describing: emptyError)) and \(String(describing: linkError))")
            return
        }
        #expect(emptyDetail == "bundled fan helper has unsafe metadata")
        #expect(linkDetail == "could not open bundled helper safely (errno \(ELOOP))")
        #expect(!FileManager.default.fileExists(atPath: fixture.paths.helper.path))
    }

    @Test("installHelper refuses a helper folder that is a file")
    func installHelperRefusesFileFolder() throws {
        let fixture = try FanServiceFixture()
        defer { fixture.remove() }
        let folder = fixture.paths.helper.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: folder.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: folder)

        let error = fanManagerError { try fixture.manager().installHelper(from: fixture.bundledHelper) }

        guard case .unsafeFile(let detail) = error else {
            Issue.record("expected unsafeFile, got \(String(describing: error))")
            return
        }
        #expect(detail == "privileged path is not a directory: \(folder.path)")
    }

    @Test("a staged copy with a bad signature is removed")
    func installHelperRemovesUnsignedStaging() throws {
        let fixture = try FanServiceFixture()
        defer { fixture.remove() }
        fixture.launchd.queue("codesign", failed(1, "staged copy is not signed"))

        let error = fanManagerError { try fixture.manager().installHelper(from: fixture.bundledHelper) }

        guard case .signatureFailed(let detail) = error else {
            Issue.record("expected signatureFailed, got \(String(describing: error))")
            return
        }
        #expect(detail == "staged copy is not signed")
        let names = try FileManager.default.contentsOfDirectory(
            atPath: fixture.paths.helper.deletingLastPathComponent().path)
        #expect(names.isEmpty)
    }

    @Test("a helper that changes during the copy is not installed")
    func installHelperDetectsSourceChange() throws {
        let fixture = try FanServiceFixture()
        defer { fixture.remove() }
        let source = fixture.bundledHelper
        let executable = fixture.executable
        var host = fixture.host()
        host.currentExecutableURL = {
            // Replace the source after the copy, before the hash check.
            try Data("helper binary BYTES".utf8).write(to: source)
            try setPermissions(0o755, source)
            return executable
        }

        let error = fanManagerError { try fixture.manager(host: host).installHelper(from: source) }

        guard case .unsafeFile(let detail) = error else {
            Issue.record("expected unsafeFile, got \(String(describing: error))")
            return
        }
        #expect(detail == "bundled fan helper changed while it was being installed")
        #expect(!FileManager.default.fileExists(atPath: fixture.paths.helper.path))
        let names = try FileManager.default.contentsOfDirectory(
            atPath: fixture.paths.helper.deletingLastPathComponent().path)
        #expect(names.isEmpty)
    }

    // MARK: launchd steps

    @Test("bootout treats a missing service as stopped")
    func bootoutAcceptsMissingService() throws {
        for output in ["Boot-out failed: 3: No such process", "could not find service \"io.darkbloom.fan\""] {
            let fixture = try FanServiceFixture(loaded: true)
            defer { fixture.remove() }
            fixture.launchd.queue("bootout", failed(3, output))

            try fixture.manager().bootoutIfLoaded()

            #expect(fixture.launchd.launchctlVerbs == ["print", "bootout"])
        }
    }

    @Test("bootout of a stopped job runs no bootout")
    func bootoutSkipsStoppedJob() throws {
        let fixture = try FanServiceFixture()
        defer { fixture.remove() }

        try fixture.manager().bootoutIfLoaded()

        #expect(fixture.launchd.launchctlVerbs == ["print"])
    }

    @Test("bootout retries three times, then reports the last error")
    func bootoutRetries() throws {
        let fixture = try FanServiceFixture(loaded: true)
        defer { fixture.remove() }
        fixture.launchd.queue(
            "bootout", failed(5, "first"), failed(5, "second"), failed(5, "third"))

        let error = fanManagerError { try fixture.manager().bootoutWithRetries() }

        guard case .launchctlFailed(let detail) = error else {
            Issue.record("expected launchctlFailed, got \(String(describing: error))")
            return
        }
        #expect(detail == "third")
        #expect(fixture.launchd.launchctlVerbs.filter { $0 == "bootout" }.count == 3)
    }

    @Test("bootout succeeds on a later attempt")
    func bootoutRetrySucceeds() throws {
        let fixture = try FanServiceFixture(loaded: true)
        defer { fixture.remove() }
        fixture.launchd.queue("bootout", failed(5, "busy"))

        try fixture.manager().bootoutWithRetries()

        #expect(fixture.launchd.launchctlVerbs == ["print", "bootout", "print", "bootout"])
        #expect(!fixture.launchd.loaded)
    }

    @Test("bootstrap accepts an already loaded job and rejects other errors")
    func bootstrapResults() throws {
        let fixture = try FanServiceFixture()
        defer { fixture.remove() }
        let manager = fixture.manager()
        fixture.launchd.queue(
            "bootstrap",
            failed(37, "Bootstrap failed: 37: Operation already in progress"),
            failed(1, "service already loaded"),
            failed(5, "Bootstrap failed: 5: Input/output error")
        )

        try manager.bootstrap()
        try manager.bootstrap()
        let error = fanManagerError { try manager.bootstrap() }

        guard case .launchctlFailed(let detail) = error else {
            Issue.record("expected launchctlFailed, got \(String(describing: error))")
            return
        }
        #expect(detail == "Bootstrap failed: 5: Input/output error")
    }

    @Test("label, kickstart and restart failures carry the launchctl output")
    func launchctlFailures() throws {
        let fixture = try FanServiceFixture()
        defer { fixture.remove() }
        let manager = fixture.manager()
        fixture.launchd.queue("enable", failed(1, "enable refused"))
        fixture.launchd.queue("kickstart", failed(1, "kickstart refused"))

        let label = fanManagerError { try manager.setLabelEnabled(true) }
        let kick = fanManagerError { try manager.kickstart() }

        guard case .launchctlFailed(let labelDetail) = label,
              case .launchctlFailed(let kickDetail) = kick
        else {
            Issue.record("expected launchctlFailed, got \(String(describing: label)) and \(String(describing: kick))")
            return
        }
        #expect(labelDetail == "enable refused")
        #expect(kickDetail == "kickstart refused")
        let kickCall = fixture.launchd.calls.last
        #expect(kickCall?.arguments == ["kickstart", "system/io.darkbloom.fan"])
    }

    @Test("a recovery restart that does not stay loaded fails")
    func restartDisabledHelperMustStayLoaded() throws {
        let fixture = try FanServiceFixture()
        defer { fixture.remove() }
        fixture.launchd.bootstrapLoads = false

        let error = fanManagerError { try fixture.manager().restartDisabledHelperForRecovery() }

        guard case .launchctlFailed(let detail) = error else {
            Issue.record("expected launchctlFailed, got \(String(describing: error))")
            return
        }
        #expect(detail == "recovery helper did not remain registered")
        #expect(fixture.launchd.launchctlVerbs == ["enable", "print", "bootstrap", "kickstart", "print"])
    }

    @Test("waitForJournalClear is true only when no journal exists")
    func journalClearWait() throws {
        let fixture = try FanServiceFixture()
        defer { fixture.remove() }
        let manager = fixture.manager()

        #expect(manager.waitForJournalClear())
        try fixture.writeJournal(fanIndices: [0])
        #expect(!manager.waitForJournalClear())
    }

    // MARK: errors

    @Test("every manager error has a fixed message")
    func errorDescriptions() {
        let cases: [(FanServiceManagerError, String)] = [
            (.rootRequired, "this operation requires administrator privileges; rerun it with sudo"),
            (.sudoUserRequired, "run this command through sudo from the provider account (SUDO_UID is required)"),
            (.invalidInvokingUID("x"), "invalid invoking user ID: x"),
            (.helperNotBundled(["a", "b"]), "signed fan helper was not found; reinstall Darkbloom (searched: a, b)"),
            (.unsafeFile("detail"), "detail"),
            (.signatureFailed("bad"), "fan helper signature verification failed: bad"),
            (.launchctlFailed("busy"), "fan launchd operation failed: busy"),
            (.unsupported("no fans"), "fan control is unavailable: no fans"),
            (.restoreFailed("stuck"), "could not verify automatic fan control: stuck"),
        ]
        for (error, expected) in cases {
            #expect(error.description == expected)
        }
        #expect(FanServiceManager.label == "io.darkbloom.fan")
        #expect(FanServiceManager.target == "system/io.darkbloom.fan")
    }
}
