/// Progress of the foreground model download (`darkbloom models download`, the
/// `darkbloom start` picker): the byte counts the streaming downloader reports
/// for each file, and the one line that shows them.

import Foundation
#if canImport(Darwin)
import Darwin
#endif

// MARK: - Byte counts

/// Bytes on disk of each file of a manifest download, fed by the streaming
/// downloader's cumulative bytes-on-disk callbacks (`ModelDownloader+HTTP.swift`)
/// and summed on a timer for the progress line. Thread-safe.
final class ManifestDownloadProgress: @unchecked Sendable {
    private struct File {
        let expectedBytes: Int64
        var bytesOnDisk: Int64
    }

    private let lock = NSLock()
    private var files: [String: File] = [:]

    /// Track a file. `initialBytes` is a resumed `.part` prefix already on disk.
    func register(label: String, expectedBytes: Int64, initialBytes: Int64 = 0) {
        lock.withLock { files[label] = File(expectedBytes: expectedBytes, bytesOnDisk: max(0, initialBytes)) }
    }

    /// The file's bytes on disk now. Fewer than before means its `.part` was
    /// discarded and the transfer restarted (the Hugging Face to R2 fallback,
    /// a checksum retry).
    func update(label: String, downloadedBytes: Int64) {
        lock.withLock { files[label]?.bytesOnDisk = downloadedBytes }
    }

    /// The file is complete at its expected size.
    func complete(label: String) {
        lock.withLock {
            guard let file = files[label], file.expectedBytes > 0 else { return }
            files[label]?.bytesOnDisk = file.expectedBytes
        }
    }

    /// Bytes on disk across every tracked file.
    var downloadedBytes: Int64 {
        lock.withLock { files.values.reduce(0) { $0 + $1.bytesOnDisk } }
    }
}

// MARK: - Output

/// Where `DownloadProgressRenderer` writes, and what it knows about it.
struct DownloadProgressTerminal: Sendable {
    /// The line can be redrawn in place: a terminal other than `TERM=dumb`.
    var isTerminal: Bool
    var columns: @Sendable () -> Int
    /// Seconds on a monotonic clock.
    var clock: @Sendable () -> TimeInterval
    var output: @Sendable (String) -> Void

    static let standardOutput = DownloadProgressTerminal(
        isTerminal: isatty(STDOUT_FILENO) != 0 && ProcessInfo.processInfo.environment["TERM"] != "dumb",
        columns: { currentColumns() },
        clock: { ProcessInfo.processInfo.systemUptime },
        output: { writeToStandardOutput($0) })

    /// The window's width, or 80 when it cannot be read.
    static func currentColumns() -> Int {
        #if canImport(Darwin)
        var size = winsize()
        if ioctl(STDOUT_FILENO, TIOCGWINSZ, &size) == 0, size.ws_col > 0 { return Int(size.ws_col) }
        #endif
        return 80
    }

    /// Writes `text` with as few `write(2)` calls as possible (normally one),
    /// after flushing stdio so it lands below everything `print` wrote first.
    static func writeToStandardOutput(_ text: String) {
        fflush(stdout)
        var bytes = Array(text.utf8)[...]
        while !bytes.isEmpty {
            let written = bytes.withUnsafeBytes { write(STDOUT_FILENO, $0.baseAddress, $0.count) }
            if written < 0 {
                if errno == EINTR { continue }
                return
            }
            bytes = bytes.dropFirst(written)
        }
    }
}

/// A foreground model download as one line (`TransferProgressLine`), indented
/// under the command's own lines.
///
/// On a terminal the line is redrawn in place (a carriage return, the line cut
/// to the window, erase to its end) at most every
/// `TransferProgressLine.redrawInterval`. It reads "Verifying …" while the files
/// are checked, and the summary or the point where the download stopped then
/// takes its place and ends it. Elsewhere (a pipe, a log, the desktop app)
/// nothing is redrawn: plain lines, the first at once, the next only after 10
/// points and 30 s, and one when the last byte arrived, then the same last lines.
final class DownloadProgressRenderer: @unchecked Sendable {
    private static let indent = "  "

    private let modelID: String
    private let terminal: DownloadProgressTerminal
    private let lock = NSLock()
    private var line: TransferProgressLine

    /// `startBytes`: the download's bytes already on disk, which the rate leaves out.
    init(modelID: String, totalBytes: Int64, startBytes: Int64, terminal: DownloadProgressTerminal = .standardOutput) {
        self.modelID = modelID
        self.terminal = terminal
        line = TransferProgressLine(label: "Downloading \(modelID)", totalBytes: totalBytes,
                                    startBytes: startBytes, startTime: terminal.clock())
    }

    /// `done`: the download's bytes on disk now.
    func update(done: Int64) {
        lock.withLock {
            let now = terminal.clock()
            if terminal.isTerminal {
                guard line.takeRedraw(now: now) else { return }
                terminal.output("\r" + Self.indent + line.text(done: done, now: now, width: liveWidth) + "\u{1B}[K")
            } else if line.takeLogLine(done: done, now: now) {
                terminal.output(Self.indent + line.text(done: done, now: now) + "\n")
            }
        }
    }

    /// Every byte is on disk; the files are being checked against the manifest.
    /// A log gets the transfer's last figures first.
    func verifying() {
        lock.withLock {
            let text = "Verifying \(modelID) (\(TransferProgressLine.bytes(line.totalBytes)))\u{2026}"
            if terminal.isTerminal {
                terminal.output("\r" + Self.indent + TransferProgressLine.clipped(text, to: liveWidth) + "\u{1B}[K")
                return
            }
            let now = terminal.clock()
            if line.takeLogLine(done: line.totalBytes, now: now, ended: true) {
                terminal.output(Self.indent + line.text(done: line.totalBytes, now: now) + "\n")
            }
            terminal.output(Self.indent + text + "\n")
        }
    }

    /// "Downloaded <model> (16.3 GB in 2m 10s)".
    func finish() {
        lock.withLock {
            var summary = "Downloaded \(modelID) (\(TransferProgressLine.bytes(line.totalBytes)) in "
                + TransferProgressLine.duration(terminal.clock() - line.startTime)
            if line.startBytes > 0 {
                summary += "; \(TransferProgressLine.bytes(line.startBytes)) of it was already on disk"
            }
            end(summary + ")")
        }
    }

    /// Where the download stopped. The caller says why.
    func fail(done: Int64) {
        lock.withLock {
            end("Download of \(modelID) stopped at \(line.percent(done: done))% "
                + "(\(TransferProgressLine.bytes(done, of: line.totalBytes)))")
        }
    }

    /// Leaves the window's last column free, so a full line never wraps.
    private var liveWidth: Int { max(1, terminal.columns() - 1 - Self.indent.count) }

    /// Takes the live line's place for good. The row is cleared first: a line
    /// longer than the window wraps, and erasing after it would cut its end.
    private func end(_ text: String) {
        terminal.output((terminal.isTerminal ? "\r\u{1B}[K" : "") + Self.indent + text + "\n")
    }
}
