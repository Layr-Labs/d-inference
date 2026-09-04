/// Per-process HuggingFace cache for fixture suites.
///
/// Suites that fabricate `models--*` snapshots (startup preload, standalone
/// server, MTP re-slice, prefetch integration) used to write them into the
/// operator's REAL `~/.cache/huggingface/hub` with defer-cleanup that a
/// crashed or killed run skipped — every later `darkbloom start`/`status`/
/// `doctor` scan then walked and Jinja-rendered the husks, and a leftover
/// fixture could be advertised by the next e2e run.
///
/// `root` is created once per test process and installed as the scanner's
/// cache-root override (`ModelScanner.setCacheDirectoryOverrideForTesting`),
/// so `ModelScanner.resolveLocalPath`, `ModelScanner.scanModels` and
/// `ModelDownloader.cacheModelDirectory` all resolve inside it. Every
/// `models--*` entry of the real cache is symlinked into the temp root
/// first, so live weight-gated suites in the same process keep finding
/// their real checkpoints (symlinked snapshots are a supported layout —
/// `SymlinkedSnapshotTest`). The directory is removed at process exit.
///
/// A Swift-level override rather than `setenv("HF_HUB_CACHE")`: Swift
/// Testing runs suites in parallel, and mutating `environ` from one suite
/// races every concurrent environment reader in the process.

import Foundation
import ProviderCore

enum TestHFCache {
    /// The per-process temp cache root. Touching this installs the override.
    static let root: URL = {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent(
                "darkbloom-tests-hf-cache-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString.prefix(8))",
                isDirectory: true)
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)

        // Mirror the real cache's model entries so live suites still resolve.
        let real = ModelScanner.resolveCacheDirectory(
            environment: ProcessInfo.processInfo.environment)
        if let entries = try? fm.contentsOfDirectory(
            at: real, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        {
            for entry in entries where entry.lastPathComponent.hasPrefix("models--") {
                try? fm.createSymbolicLink(
                    at: root.appendingPathComponent(entry.lastPathComponent, isDirectory: true),
                    withDestinationURL: entry)
            }
        }

        ModelScanner.setCacheDirectoryOverrideForTesting(root)
        let path = root.path
        atexit_b { try? FileManager.default.removeItem(atPath: path) }
        return root
    }()

    /// `<root>/models--{org}--{name}` for `modelId`.
    static func modelDirectory(for modelId: String) -> URL {
        root.appendingPathComponent(
            "models--\(modelId.replacingOccurrences(of: "/", with: "--"))", isDirectory: true)
    }

    /// The downloader's `snapshots/local` directory for `modelId`, under the
    /// temp root. Touching `root` first installs the override, so the
    /// production downloader/scanner then resolve the same location.
    static func snapshotDirectory(for modelId: String) -> URL {
        modelDirectory(for: modelId)
            .appendingPathComponent("snapshots", isDirectory: true)
            .appendingPathComponent("local", isDirectory: true)
    }

    /// Create a minimal fake HF-cache snapshot so `ModelScanner.resolveLocalPath`
    /// resolves `modelId` (the load paths require an on-disk snapshot BEFORE
    /// they reach the admission gates under test). `files` are written into
    /// the snapshot; the default is a config-only snapshot. Returns the
    /// `models--...` directory for cleanup.
    @discardableResult
    static func makeFakeSnapshot(
        modelId: String,
        files: [String: Data] = ["config.json": Data("{}".utf8)]
    ) throws -> URL {
        let modelDir = modelDirectory(for: modelId)
        // Never write THROUGH a mirrored real-cache entry: if a real
        // `models--<id>` of this name was symlinked in at setup (a leftover
        // husk from an older run), drop the LINK — only the link — so the
        // fixture lands in the temp root. `attributesOfItem` does not
        // traverse symlinks, so this sees the link itself.
        if let type = try? FileManager.default.attributesOfItem(atPath: modelDir.path)[.type]
            as? FileAttributeType, type == .typeSymbolicLink
        {
            try FileManager.default.removeItem(at: modelDir)
        }
        let snapshot = modelDir
            .appendingPathComponent("snapshots", isDirectory: true)
            .appendingPathComponent("main", isDirectory: true)
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
        for (name, bytes) in files {
            try bytes.write(to: snapshot.appendingPathComponent(name))
        }
        return modelDir
    }
}
