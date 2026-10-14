import Darwin
import Foundation
import Testing
@testable import ProviderCore

/// F17 (round 6b soak run 2): the member's cluster service ran out of file descriptors about 18 minutes after it started
/// (`open("/")` failed: "Cannot open configuration root"). From then on every read of its setup record failed, so it took
/// the failed read for "the leader stopped serving", stopped its part, and never started it again while it logged "the
/// leader serves: recorded" for a write that failed every 5 s. These checks hold the service's descriptor count flat across
/// the operations it repeats for as long as it runs: setup record writes (every control tick and lease), the command lock
/// (every forwarded command and hand-over), and no caller that opens a configuration directory and drops its descriptor.
/// Files in a temporary folder only: no cable, no peer Mac, no model.
@Suite(.serialized) struct ClusterServiceDescriptorTests {
    /// Descriptors open in this process now.
    static func openDescriptors() -> Int {
        let limit = min(Int(getdtablesize()), 65_536)
        return (0..<limit).reduce(0) { $0 + (fcntl(Int32($1), F_GETFD) != -1 ? 1 : 0) }
    }

    /// A private folder on a path with no symbolic link in it (the strict configuration reader refuses `/var`).
    static func temporaryHome() throws -> URL {
        var resolved = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard realpath(NSTemporaryDirectory(), &resolved) != nil else { throw POSIXError(.ENOENT) }
        let base = URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
            .appendingPathComponent("f17-descriptors-" + UUID().uuidString.prefix(8), isDirectory: true)
        guard mkdir(base.path, 0o700) == 0 else { throw POSIXError(.EEXIST) }
        return base
    }

    @Test func setupRecordWritesKeepDescriptorsFlat() throws {
        let home = try Self.temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let store = ClusterSetupStore(paths: .init(paths: try ClusterUserPaths(homeDirectory: home)))
        _ = try store.updateRecord { _ in }
        let before = Self.openDescriptors()
        let writes = 200
        for index in 0..<writes {
            // The control tick's write (unchanged record) and the lease's write (a changed one) both count.
            _ = try store.updateRecord { record in if index % 2 == 0 { record.aloneHoldersPlan = "plan-\(index)" } }
            _ = try store.readRecord()
        }
        let grown = Self.openDescriptors() - before
        #expect(grown < writes / 4, "\(grown) descriptors still open after \(writes) setup record writes")
    }

    @Test func commandLockKeepsDescriptorsFlat() throws {
        let home = try Self.temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let file = home.appendingPathComponent("service", isDirectory: true).appendingPathComponent("control.lock")
        ClusterControlCommandLock.acquire(seconds: 0, file: file)?.release()
        let before = Self.openDescriptors()
        let rounds = 100
        for _ in 0..<rounds {
            let held = try #require(ClusterControlCommandLock.acquire(seconds: 0, file: file))
            held.release()
        }
        let grown = Self.openDescriptors() - before
        #expect(grown < rounds / 4, "\(grown) descriptors still open after \(rounds) command locks")
    }

    /// `ClusterConfigurationFiles.directory` returns an open descriptor: a caller that only needs the folder to exist and
    /// discards the result leaks one descriptor per call.
    @Test func noCallerDiscardsAnOpenedConfigurationDirectory() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources", isDirectory: true)
        let pattern = try NSRegularExpression(pattern: #"_\s*=\s*try[?!]?\s*ClusterConfigurationFiles\.directory\("#)
        var offenders: [String] = []
        let walker = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var scanned = 0
        for case let url as URL in walker where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            scanned += 1
            for (number, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let value = String(line)
                if pattern.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) != nil {
                    offenders.append("\(url.lastPathComponent):\(number + 1)")
                }
            }
        }
        #expect(scanned > 100, "the provider sources were found (\(scanned) files)")
        #expect(offenders.isEmpty, "opened directory descriptors discarded at \(offenders.joined(separator: ", "))")
    }

    // MARK: - A failed write or read is said and acted on, never swallowed

    @Test func aFailedIntentWriteIsAStatedFailureNotRecorded() {
        var said: [String] = []
        let failure = ClusterLeaseIntentRecording.record(true, write: { throw ClusterConfigurationError.invalid("Cannot open configuration root") },
                                                         say: { said.append($0) })
        #expect(failure != nil, "the lease is refused with the reason")
        #expect(failure?.text.contains("Cannot open configuration root") == true, "\(failure?.text ?? "")")
        #expect(said == ["the leader serves: could not record it (Cannot open configuration root)"], "\(said)")
        said.removeAll()
        #expect(ClusterLeaseIntentRecording.record(false, write: {}, say: { said.append($0) }) == nil)
        #expect(said == ["the leader stopped serving: recorded"], "\(said)")
    }

    @Test func aFailedRecordReadKeepsThePartInsteadOfStoppingIt() {
        switch ClusterService.supervisedRecord({ throw ClusterConfigurationError.invalid("Cannot open configuration root") }) {
        case .success: Issue.record("a failed read must not read as a record (whose leader does not serve)")
        case .failure(let failure): #expect(failure.text == "cannot read this Mac's setup record (Cannot open configuration root)", "\(failure.text)")
        }
        var record = ClusterSetupRecord()
        record.aloneHoldersPlan = "p"
        let read = ClusterService.supervisedRecord({ record })
        #expect((try? read.get())?.aloneHoldersPlan == "p")
    }
}
