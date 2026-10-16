import Darwin
import Foundation

// The prompt-prefix tiers' model-free decisions, from the runtime's sources.

private struct Failure: Error, CustomStringConvertible { let description: String }
private func require(_ condition: Bool, _ message: @autoclosure () -> String) throws {
    guard condition else { throw Failure(description: message()) }
}

@main struct PrefixPolicyCheck {
    static func main() {
        var passed = 0
        func check(_ name: String, _ body: () throws -> Void) {
            do { try body(); passed += 1; print("ok \(name)") }
            catch { FileHandle.standardError.write(Data("FAILED \(name): \(error)\n".utf8)); exit(1) }
        }
        let gib: UInt64 = 1 << 30, mib = 1 << 20
        typealias Policy = QwenStagePrefixDiskPolicy

        check("a-restore-deletes-only-a-record-that-failed-itself") {
            struct Integrity: Error {}
            try require(Policy.deletesRecord(after: Integrity(), checkFailed: false, injected: false), "an integrity failure keeps the record")
            for code in [EIO, EINTR, EAGAIN, EMFILE, ENFILE, ENOMEM, EBUSY] {
                try require(!Policy.deletesRecord(after: Policy.IOFailure("read", code: code), checkFailed: false, injected: false),
                            "transient I/O (errno \(code)) deleted the record")
            }
            try require(Policy.deletesRecord(after: Policy.IOFailure("open", code: ENOENT), checkFailed: false, injected: false),
                        "a record that is gone stays indexed")
            try require(!Policy.deletesRecord(after: Integrity(), checkFailed: true, injected: false), "a failed request check deleted the record")
            try require(!Policy.deletesRecord(after: Integrity(), checkFailed: false, injected: true), "an injected fault deleted the record")
        }
        check("a-record-restores-only-on-the-rank-its-header-names") {
            try require(Policy.belongs(headerRank: 1, to: 1), "own rank")
            try require(!Policy.belongs(headerRank: 0, to: 1), "another rank's record")
            try require(!Policy.belongs(headerRank: nil, to: 0), "a record that names no rank")
        }
        check("the-writer-queue-bound-follows-the-macs-memory") {
            try require(Policy.queuedBytesBound(physicalBytes: 256 * gib) == 4 << 30, "256 GB")
            try require(Policy.queuedBytesBound(physicalBytes: 64 * gib) == 1 << 30, "64 GB")
            try require(Policy.queuedBytesBound(physicalBytes: 16 * gib) == 256 * mib, "16 GB")
            try require(Policy.queuedBytesBound(physicalBytes: 8 * gib) == 256 * mib, "8 GB keeps one large record's copy")
            try require(QwenStagePrefixDiskConfiguration(mode: .off(sweepRoot: nil, reason: "t")).maximumQueuedBytes
                        == Policy.queuedBytesBound(physicalBytes: ProcessInfo.processInfo.physicalMemory), "configuration default not derived")
        }
        check("the-resident-ceiling-follows-the-macs-memory") {
            try require(Policy.residentCeilingBytes(physicalBytes: 256 * gib) == 8 << 30, "256 GB")
            try require(Policy.residentCeilingBytes(physicalBytes: 128 * gib) == 4 << 30, "128 GB")
            try require(Policy.residentCeilingBytes(physicalBytes: 64 * gib) == 2 << 30, "64 GB")
            try require(Policy.residentCeilingBytes(physicalBytes: 24 * gib) == 768 * mib, "24 GB in 256 MiB steps")
            try require(Policy.residentCeilingBytes(physicalBytes: 4 * gib) == 256 * mib, "at least one step")
        }
        check("the-close-fits-the-plans-stop-margin") {
            for margin in [15_000, 20_000, 25_000] {
                let bounds = Policy.closeBounds(stopMarginMilliseconds: margin)
                try require(abs(bounds.longestSeconds - Double(margin) / 1000) < 1e-9, "margin \(margin): longest \(bounds.longestSeconds) s")
            }
            let none = Policy.closeBounds(stopMarginMilliseconds: nil)
            try require(none.boundSeconds == 20 && none.finalSeconds == 5, "without a margin the dead-man stands in (20 s, 5 s)")
            // The key arrives on the worker's input (ssd-key-stdin), never in the environment.
            let key = Data(repeating: 0xab, count: 32)
            let base = ["DARKBLOOM_CLUSTER_PREFIX_SSD_DIR": "/tmp/prefix-policy"]
            var with = base; with["DARKBLOOM_CLUSTER_PREFIX_SSD_STOP_MARGIN_MS"] = "20000"
            try require(QwenStagePrefixDiskConfiguration.fromEnvironment(with, key: key).closeBounds == Policy.closeBounds(stopMarginMilliseconds: 20_000),
                        "the owner's stop margin is not read")
            var silly = base; silly["DARKBLOOM_CLUSTER_PREFIX_SSD_STOP_MARGIN_MS"] = "5"
            try require(QwenStagePrefixDiskConfiguration.fromEnvironment(silly, key: key).closeBounds == none, "an out-of-range margin is ignored")
            try require(QwenStagePrefixDiskConfiguration.fromEnvironment(base, key: key).closeBounds == none, "no margin: the default")
        }
        print("{\"passed\":true,\"cases\":\(passed),\"prefixPolicy\":\"actual-runtime-sources\",\"modelOrGPUExecution\":false}")
    }
}
