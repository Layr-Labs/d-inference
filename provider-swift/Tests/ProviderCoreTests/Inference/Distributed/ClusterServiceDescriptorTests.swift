import Darwin
import Foundation
import DarkbloomClusterProtocol
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
    /// Descriptors open in this process now on `folder` or anything under it (other suites running at the same time open
    /// their own descriptors elsewhere and are not counted).
    static func openDescriptors(under folder: URL) -> Int {
        let limit = min(Int(getdtablesize()), 65_536)
        let prefix = folder.path
        var count = 0
        for fd in 0..<Int32(limit) where fcntl(fd, F_GETFD) != -1 {
            var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            guard fcntl(fd, F_GETPATH, &buffer) != -1 else { continue }
            let path = String(cString: buffer)
            if path == prefix || path.hasPrefix(prefix + "/") { count += 1 }
        }
        return count
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
        let before = Self.openDescriptors(under: home)
        let writes = 200
        for index in 0..<writes {
            // The control tick's write (unchanged record) and the lease's write (a changed one) both count.
            _ = try store.updateRecord { record in if index % 2 == 0 { record.aloneHoldersPlan = "plan-\(index)" } }
            _ = try store.readRecord()
        }
        let grown = Self.openDescriptors(under: home) - before
        #expect(grown < writes / 4, "\(grown) descriptors still open after \(writes) setup record writes")
    }

    @Test func commandLockKeepsDescriptorsFlat() throws {
        let home = try Self.temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let file = home.appendingPathComponent("service", isDirectory: true).appendingPathComponent("control.lock")
        ClusterControlCommandLock.acquire(seconds: 0, file: file)?.release()
        let before = Self.openDescriptors(under: home)
        let rounds = 100
        for _ in 0..<rounds {
            let held = try #require(ClusterControlCommandLock.acquire(seconds: 0, file: file))
            held.release()
        }
        let grown = Self.openDescriptors(under: home) - before
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

    // MARK: - F18: the service's forever loops drain what each tick autoreleases

    /// The service's two loops (control tick, supervise) never return to a run loop, so without a pool per iteration every
    /// autoreleased Foundation object lives until the service ends. Round 6b's services grew about 15 MB a minute; a heap
    /// of one showed 1.47 M CFStrings and 5,147 autorelease pool pages after 15 minutes.
    @Test func serviceLoopsDrainAnAutoreleasePoolEachTick() throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/ProviderCore/Inference/Distributed/Onboarding/ClusterService.swift")
        let lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        func loopDrains(_ header: String) -> Bool {
            guard let start = lines.firstIndex(where: { $0.contains(header) }) else { return false }
            return lines[(start + 1)..<min(lines.count, start + 8)].contains { $0.contains("autoreleasepool {") }
        }
        #expect(loopDrains("while let self, !self.lock.withLock({ self.stopping }) {"), "the control tick loop")
        #expect(loopDrains("while !stopped {"), "the supervise loop")
    }

    /// Rank 0 sends the worker a command frame per decoded token (`tokenDecision`), encoded with JSONSerialization, from
    /// threads and queues that never drain an autorelease pool: each frame left its writer and a 4 KB NSData behind (rank
    /// 0 grew about 40 MB a minute under load; its heap held thousands of `_NSJSONWriter` buffers). Encoding and decoding
    /// frames on such a thread keeps the bytes in use flat.
    @Test func workerFramesLeaveNothingOnAThreadThatNeverDrains() throws {
        func inUse() -> Int {
            var stats = malloc_statistics_t()
            malloc_zone_statistics(nil, &stats)
            return Int(stats.size_in_use)
        }
        let frames = 20_000
        let finished = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var grown = 0
        nonisolated(unsafe) var failure: Error?
        Thread.detachNewThread {
            defer { finished.signal() }
            do {
                let epoch = UUID()
                let warm = try ClusterWorkerCodec.encode(ClusterWorkerCommandFrame(membershipEpoch: epoch, sequence: 0, requestID: nil,
                                                                                   command: .keepWarm(ordinal: 1)))
                _ = try ClusterWorkerCodec.decodeCommand(warm)
                let before = inUse()
                for index in 0..<frames {
                    let data = try ClusterWorkerCodec.encode(ClusterWorkerCommandFrame(membershipEpoch: epoch, sequence: UInt64(index),
                                                                                       requestID: nil, command: .keepWarm(ordinal: 1)))
                    _ = try ClusterWorkerCodec.decodeCommand(data)
                }
                grown = inUse() - before
            } catch { failure = error }
        }
        finished.wait()
        #expect(failure == nil, "\(String(describing: failure))")
        #expect(grown < 32 * 1024 * 1024, "\(grown / 1024) KiB still in use after \(frames) worker frames on a thread that never drains")
    }
}
