import Foundation
import Testing

@testable import darkbloom

private let summary = ToolConfigSummary(provider: .added, models: ["m"], defaultModel: nil)

/// A plan that appends `marker` once: unchanged when the file already ends with it.
private func appending(_ marker: String) -> (Data?) -> ToolConfigPlan {
    { existing in
        let text = String(decoding: existing ?? Data(), as: UTF8.self)
        if text.hasSuffix(marker) { return .unchanged(summary) }
        return .change(Data((text + marker).utf8), summary)
    }
}

/// A clock that moves one second per reading, from 2026-11-06T22:15:00Z.
private final class SteppingClock: @unchecked Sendable {
    private let lock = NSLock()
    private var next = Date(timeIntervalSince1970: 1_794_003_300)

    func read() -> Date {
        lock.withLock {
            defer { next = next.addingTimeInterval(1) }
            return next
        }
    }
}

private func writer(_ directory: TemporaryDirectory, tool: IntegrationTool = .opencode,
                    clock: SteppingClock = SteppingClock()) -> ToolConfigWriter {
    var writer = ToolConfigWriter(tool: tool, stateDirectory: directory.file("state/integrations"))
    writer.now = { clock.read() }
    return writer
}

private func backups(_ directory: TemporaryDirectory, tool: String = "opencode") -> [String] {
    let folder = directory.file("state/integrations/backups/\(tool)")
    return ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
}

private func shell(_ command: String) throws -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", command]
    try process.run()
    process.waitUntilExit()
    return process.terminationStatus
}

@Suite("Tool config writer")
struct ToolConfigWriterTests {
    @Test("a new file gets the tool's mode, no backup, and an undo that removes it")
    func createsAFile() throws {
        let directory = try TemporaryDirectory()
        let file = directory.file("config/opencode/opencode.jsonc")
        let outcome = try writer(directory).apply(to: file, newFileMode: 0o644, plan: appending("A"))
        #expect(outcome == .written(file: file, backup: nil, undo: "rm '\(file.path)'", summary))
        #expect(try String(contentsOf: file, encoding: .utf8) == "A")
        #expect(posixMode(file) == 0o644)
        #expect(backups(directory).isEmpty)

        let hermes = directory.file("hermes/config.yaml")
        _ = try writer(directory, tool: .hermes).apply(to: hermes, newFileMode: 0o600, plan: appending("B"))
        #expect(posixMode(hermes) == 0o600)
    }

    @Test("a change backs up the exact bytes first (0600, folder 0700), keeps the file's mode, and the undo restores it")
    func backsUpAndUndoes() throws {
        let directory = try TemporaryDirectory()
        let original = "{\n  // owner's\n  \"model\": \"x\"\n}\n"
        let file = try directory.write(original, to: "opencode.jsonc", mode: 0o640)
        let outcome = try writer(directory).apply(to: file, newFileMode: 0o644, plan: appending("!"))
        guard case .written(let written, let backup?, let undo, _) = outcome else {
            Issue.record("expected a written outcome with a backup, got \(outcome)")
            return
        }
        #expect(written == file)
        #expect(backup.lastPathComponent == "opencode.jsonc.20261106T221500Z")
        #expect(backup.deletingLastPathComponent().path
            == directory.file("state/integrations/backups/opencode").path)
        #expect(try Data(contentsOf: backup) == Data(original.utf8))
        #expect(posixMode(backup) == 0o600)
        #expect(posixMode(backup.deletingLastPathComponent()) == 0o700)
        #expect(posixMode(file) == 0o640)
        #expect(try String(contentsOf: file, encoding: .utf8) == original + "!")
        #expect(undo == "cp '\(backup.path)' '\(file.path)'")

        #expect(try shell(undo) == 0)
        #expect(try Data(contentsOf: file) == Data(original.utf8))
    }

    @Test("an unchanged plan writes nothing and makes no backup")
    func unchangedWritesNothing() throws {
        let directory = try TemporaryDirectory()
        let file = try directory.write("doneA", to: "opencode.jsonc")
        let before = try FileManager.default.attributesOfItem(atPath: file.path)
        let outcome = try writer(directory).apply(to: file, newFileMode: 0o644, plan: appending("A"))
        #expect(outcome == .unchanged(file: file, summary))
        let after = try FileManager.default.attributesOfItem(atPath: file.path)
        #expect(before[.systemFileNumber] as? Int == after[.systemFileNumber] as? Int)
        #expect(backups(directory).isEmpty)
    }

    @Test("the five newest backups of each file are kept, also within one second")
    func keepsFiveBackups() throws {
        let directory = try TemporaryDirectory()
        let file = try directory.write("0", to: "opencode.json")
        let other = try directory.write("0", to: "opencode.jsonc")
        let clock = SteppingClock()
        let edits = writer(directory, clock: clock)
        for step in 1...7 {
            _ = try edits.apply(to: file, newFileMode: 0o644) { _ in .change(Data("\(step)".utf8), summary) }
        }
        _ = try edits.apply(to: other, newFileMode: 0o644) { _ in .change(Data("x".utf8), summary) }
        let kept = backups(directory)
        #expect(kept.filter { $0.hasPrefix("opencode.json.") } == [
            "opencode.json.20261106T221502Z", "opencode.json.20261106T221503Z", "opencode.json.20261106T221504Z",
            "opencode.json.20261106T221505Z", "opencode.json.20261106T221506Z",
        ])
        #expect(kept.filter { $0.hasPrefix("opencode.jsonc.") } == ["opencode.jsonc.20261106T221507Z"])
        let newest = directory.file("state/integrations/backups/opencode/opencode.json.20261106T221506Z")
        #expect(try String(contentsOf: newest, encoding: .utf8) == "6")

        var sameSecond = writer(directory)
        sameSecond.now = { Date(timeIntervalSince1970: 1_893_456_000) }
        for step in 8...9 {
            _ = try sameSecond.apply(to: file, newFileMode: 0o644) { _ in .change(Data("\(step)".utf8), summary) }
        }
        #expect(backups(directory).filter { $0.hasPrefix("opencode.json.2030") }
            == ["opencode.json.20300101T000000Z", "opencode.json.20300101T000000Z-2"])
    }

    @Test("a failure between writing the new bytes and replacing the file leaves the file intact")
    func failedReplaceLeavesTheFile() throws {
        struct Crash: Error {}
        let directory = try TemporaryDirectory()
        let file = try directory.write("intact", to: "config.yaml")
        var crashing = writer(directory, tool: .hermes)
        crashing.beforeReplace = { _ in throw Crash() }
        #expect(throws: Crash.self) {
            try crashing.apply(to: file, newFileMode: 0o600, plan: appending("X"))
        }
        #expect(try String(contentsOf: file, encoding: .utf8) == "intact")
        let siblings = try FileManager.default.contentsOfDirectory(atPath: directory.url.path)
        #expect(siblings.filter { $0.contains(".darkbloom-") }.isEmpty)
    }

    @Test("a symlinked config is written through: the link stays a link and its target changes")
    func symlinkedConfig() throws {
        let directory = try TemporaryDirectory()
        let target = try directory.write("dotfiles", to: "dotfiles/opencode.jsonc", mode: 0o600)
        let link = directory.file("config/opencode.jsonc")
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let outcome = try writer(directory).apply(to: link, newFileMode: 0o644, plan: appending("+"))
        guard case .written(_, let backup?, let undo, _) = outcome else {
            Issue.record("expected a written outcome with a backup, got \(outcome)")
            return
        }
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == target.path)
        #expect(try String(contentsOf: target, encoding: .utf8) == "dotfiles+")
        #expect(posixMode(target) == 0o600)
        #expect(try String(contentsOf: backup, encoding: .utf8) == "dotfiles")
        #expect(undo == "cp '\(backup.path)' '\(link.path)'")

        let dangling = directory.file("config/dangling.jsonc")
        try FileManager.default.createSymbolicLink(at: dangling, withDestinationURL: directory.file("missing.jsonc"))
        let refused = try writer(directory).apply(to: dangling, newFileMode: 0o644, plan: appending("+"))
        guard case .refused(_, let refusal) = refused else {
            Issue.record("expected a refusal, got \(refused)")
            return
        }
        #expect(refusal.kind == .file)
    }

    @Test("a change made by someone else during the edit is planned again once, and twice refuses")
    func concurrentEdits() throws {
        let directory = try TemporaryDirectory()
        let file = try directory.write("base", to: "config.yaml")
        var plans = 0
        var once = writer(directory, tool: .hermes)
        var raced = false
        once.beforeReplace = { url in
            guard !raced else { return }
            raced = true
            try Data("theirs".utf8).write(to: url)
        }
        let outcome = try once.apply(to: file, newFileMode: 0o600) { existing in
            plans += 1
            return appending("+mine")(existing)
        }
        guard case .written = outcome else {
            Issue.record("expected a written outcome, got \(outcome)")
            return
        }
        #expect(plans == 2)
        #expect(try String(contentsOf: file, encoding: .utf8) == "theirs+mine")

        var always = writer(directory, tool: .hermes)
        var round = 0
        always.beforeReplace = { url in
            round += 1
            try Data("theirs \(round)".utf8).write(to: url)
        }
        let refused = try always.apply(to: file, newFileMode: 0o600, plan: appending("+again"))
        #expect(refused == .refused(
            file: file, .file("it changed while Darkbloom was editing it; run this again")))
        #expect(try String(contentsOf: file, encoding: .utf8) == "theirs 2")
    }

    @Test("a dry run plans without touching anything: no file, no backup, no state folder")
    func dryRun() throws {
        let directory = try TemporaryDirectory()
        let file = directory.file("opencode/opencode.jsonc")
        let planned = try writer(directory).apply(to: file, newFileMode: 0o644, dryRun: true, plan: appending("A"))
        #expect(planned == .planned(file: file, contents: Data("A".utf8), summary))
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(!FileManager.default.fileExists(atPath: directory.file("state").path))

        let existing = try directory.write("old", to: "opencode/opencode.json")
        _ = try writer(directory).apply(to: existing, newFileMode: 0o644, dryRun: true, plan: appending("A"))
        #expect(try String(contentsOf: existing, encoding: .utf8) == "old")
        #expect(!FileManager.default.fileExists(atPath: directory.file("state").path))
    }

    @Test("a refused plan or a path that isn't a regular file writes nothing")
    func refusalsWriteNothing() throws {
        let directory = try TemporaryDirectory()
        let file = try directory.write("{", to: "opencode.json")
        let refusal = ToolConfigRefusal.file("it isn't valid JSON (line 1)")
        #expect(try writer(directory).apply(to: file, newFileMode: 0o644) { _ in .refused(refusal) }
            == .refused(file: file, refusal))
        #expect(try String(contentsOf: file, encoding: .utf8) == "{")
        #expect(backups(directory).isEmpty)

        let folder = directory.file("folder.jsonc")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let notAFile = try writer(directory).apply(to: folder, newFileMode: 0o644, plan: appending("A"))
        #expect(notAFile == .refused(file: folder, .file("it isn't a regular file")))
    }
}
