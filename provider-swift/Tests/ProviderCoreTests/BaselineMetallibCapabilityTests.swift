import Foundation
import Testing

@testable import ProviderCore

@Suite("baseline metallib capability")
struct BaselineMetallibCapabilityTests {
    private func makeApp(
        baseline: String?,
        marker: String?
    ) throws -> URL {
        let fm = FileManager.default
        let app = fm.temporaryDirectory.appendingPathComponent(
            "baseline-metallib-\(UUID().uuidString)/Darkbloom.app",
            isDirectory: true)
        try fm.createDirectory(at: app, withIntermediateDirectories: true)
        if let baseline {
            let url = app.appendingPathComponent(
                PackagedMetallib.baselineBundleRelativePath)
            try fm.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try Data(baseline.utf8).write(to: url)
        }
        if let marker {
            let url = app.appendingPathComponent(
                PackagedMetallib.baselineCapabilityRelativePath)
            try fm.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try Data(marker.utf8).write(to: url)
        }
        return app
    }

    @Test("a complete baseline pair verifies")
    func completePairPasses() throws {
        let app = try makeApp(baseline: "metallib", marker: "1\n")
        defer { try? FileManager.default.removeItem(at: app) }
        try BaselineMetallibCapabilityVerifier.verify(app: app)
    }

    // Releases before the two-library layout ship neither half and must keep
    // self-updating; the marker is what distinguishes them from a broken stage.
    @Test("pre-baseline releases stay verifiable")
    func absentPairPasses() throws {
        let app = try makeApp(baseline: nil, marker: nil)
        defer { try? FileManager.default.removeItem(at: app) }
        try BaselineMetallibCapabilityVerifier.verify(app: app)
    }

    @Test("half a pair is rejected")
    func halfPairsRejected() throws {
        for (baseline, marker) in [("metallib", String?.none), (nil, "1\n")] {
            let app = try makeApp(baseline: baseline, marker: marker)
            defer { try? FileManager.default.removeItem(at: app) }
            #expect(throws: UpdateError.self) {
                try BaselineMetallibCapabilityVerifier.verify(app: app)
            }
        }
    }

    @Test("an empty library or a bad marker is rejected")
    func malformedPairsRejected() throws {
        for (baseline, marker) in [("", "1\n"), ("metallib", "0\n")] {
            let app = try makeApp(baseline: baseline, marker: marker)
            defer { try? FileManager.default.removeItem(at: app) }
            #expect(throws: UpdateError.self) {
                try BaselineMetallibCapabilityVerifier.verify(app: app)
            }
        }
    }

    // MLX resolves its metallib probes against the RUNNING executable's
    // directory, so a `$PATH` invocation through `bin/darkbloom` probes `bin/`,
    // not the bundle. That is why `bin/mlx.metallib` exists; without the same
    // mirror for the baseline, a macOS 15 host has no fallback for any
    // foreground command even though the bundle ships one.
    @Test("canonical app links mirror the baseline library into bin/")
    func canonicalLinksMirrorBaseline() throws {
        let fixture = try UpdateRecoveryFixture()
        defer { fixture.cleanup() }
        let store = UpdateRecoveryStore(
            installRoot: fixture.installRoot,
            verifyCodeSignatures: false)

        // The fixture's initial links model a pre-baseline install.
        #expect(try fixture.liveBaselineMetallibContents() == nil)

        try store.ensureCanonicalLinks(layout: .app)
        #expect(
            try fixture.liveBaselineMetallibContents() == "1.0.0-baseline-metallib")

        // Downgrading onto a pre-baseline app must retire the mirror, not leave
        // a dangling probe MLX tries before giving up.
        try FileManager.default.removeItem(
            at: fixture.installRoot.appendingPathComponent(
                "Darkbloom.app/\(PackagedMetallib.baselineBundleRelativePath)"))
        try store.ensureCanonicalLinks(layout: .app)
        #expect(try fixture.liveBaselineMetallibContents() == nil)
    }

    @Test("a symlinked library is rejected")
    func symlinkRejected() throws {
        let fm = FileManager.default
        let app = try makeApp(baseline: nil, marker: "1\n")
        defer { try? fm.removeItem(at: app) }
        let baseline = app.appendingPathComponent(
            PackagedMetallib.baselineBundleRelativePath)
        try fm.createDirectory(
            at: baseline.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        let primary = app.appendingPathComponent("Contents/MacOS/mlx.metallib")
        try Data("metallib".utf8).write(to: primary)
        try fm.createSymbolicLink(atPath: baseline.path, withDestinationPath: "../mlx.metallib")

        #expect(throws: UpdateError.self) {
            try BaselineMetallibCapabilityVerifier.verify(app: app)
        }
    }
}
