/// Download progress tracking + terminal rendering for the foreground model
/// download path (`darkbloom models download` / the interactive picker).
///
/// Split out of `ModelCatalog.swift` so that file stays focused on catalog +
/// download orchestration. The tracker here is callback-driven (fed by the
/// streaming, byte-resumable downloader in `ModelCatalog.swift`) rather than a
/// `URLSessionDownloadDelegate`: downloads now stream straight to a `.part`
/// file for true byte-level resume, so there is no `URLSessionDownloadTask` to
/// observe — progress arrives as cumulative-bytes-on-disk callbacks instead.

import Foundation
#if canImport(Darwin)
import Darwin
#endif

// MARK: - Per-file progress

/// Per-file progress state rendered by `ProgressRenderer`.
struct FileProgress: Sendable {
    let label: String
    let expectedBytes: Int64
    var downloadedBytes: Int64 = 0
    /// Bytes already on disk when tracking started (a resumed `.part` prefix).
    /// Excluded from the speed/ETA math so a resume doesn't report an inflated
    /// instantaneous rate for bytes it never actually transferred this run.
    var baselineBytes: Int64 = 0
    var startTime: Date = Date()
    var completed: Bool = false
    var completionTime: Date?

    /// Bytes/second over this run's transfer (excludes the resumed prefix).
    var speed: Double {
        let elapsed = (completionTime ?? Date()).timeIntervalSince(startTime)
        guard elapsed > 0.1 else { return 0 }
        return Double(max(0, downloadedBytes - baselineBytes)) / elapsed
    }

    /// Estimated seconds remaining.
    var eta: Double? {
        guard speed > 0, expectedBytes > 0 else { return nil }
        let remaining = Double(expectedBytes - downloadedBytes)
        guard remaining > 0 else { return nil }
        return remaining / speed
    }

    var fraction: Double {
        guard expectedBytes > 0 else { return 0 }
        return min(1.0, Double(downloadedBytes) / Double(expectedBytes))
    }
}

// MARK: - Tracker

/// Thread-safe per-file download progress keyed by file label (manifest path).
///
/// Fed by byte-progress callbacks from the streaming downloader and read on a
/// timer by `ProgressRenderer`. Registration order is preserved so the rendered
/// rows stay stable across frames.
final class ManifestDownloadProgress: @unchecked Sendable {

    private let lock = NSLock()
    private var progress: [String: FileProgress] = [:]
    private var order: [String] = []

    /// Register a file to track. `initialBytes` seeds a resumed `.part` prefix
    /// so the bar starts where the previous run left off (and is excluded from
    /// the speed math via `baselineBytes`).
    func register(label: String, expectedBytes: Int64, initialBytes: Int64 = 0) {
        lock.lock()
        defer { lock.unlock() }
        if progress[label] == nil { order.append(label) }
        var p = FileProgress(label: label, expectedBytes: expectedBytes)
        p.downloadedBytes = max(0, initialBytes)
        p.baselineBytes = max(0, initialBytes)
        progress[label] = p
    }

    /// Update cumulative bytes-on-disk for a file.
    func update(label: String, downloadedBytes: Int64) {
        lock.lock()
        defer { lock.unlock() }
        guard var p = progress[label] else { return }
        p.downloadedBytes = downloadedBytes
        progress[label] = p
    }

    /// Mark a file complete (full size, stop the clock).
    func complete(label: String) {
        lock.lock()
        defer { lock.unlock() }
        guard var p = progress[label] else { return }
        p.downloadedBytes = p.expectedBytes > 0 ? p.expectedBytes : p.downloadedBytes
        p.completed = true
        p.completionTime = Date()
        progress[label] = p
    }

    /// Thread-safe snapshot of all tracked file progress, in registration order.
    var allProgress: [FileProgress] {
        lock.lock()
        defer { lock.unlock() }
        return order.compactMap { progress[$0] }
    }
}

// MARK: - Renderer

/// Renders a multi-line progress display to the terminal using ANSI escape
/// codes. Falls back to simple per-file messages when stdout is not a TTY.
final class ProgressRenderer: @unchecked Sendable {

    private let isTTY: Bool
    private var linesPrinted: Int = 0
    private let lock = NSLock()
    /// Set of labels already printed in non-TTY mode.
    private var printedLabels: Set<String> = []

    init() {
        self.isTTY = isatty(STDOUT_FILENO) != 0
    }

    /// Render a frame given the current file progress snapshot.
    func render(_ files: [FileProgress]) {
        lock.lock()
        defer { lock.unlock() }

        if !isTTY {
            renderPlain(files)
            return
        }
        renderANSI(files)
    }

    /// Final render: clear the progress area and print completion summary.
    func finish(_ files: [FileProgress]) {
        lock.lock()
        defer { lock.unlock() }

        if isTTY {
            // Move up and clear all lines.
            if linesPrinted > 0 {
                print("\u{1B}[\(linesPrinted)A", terminator: "")
                for _ in 0..<linesPrinted {
                    print("\u{1B}[2K")
                }
                print("\u{1B}[\(linesPrinted)A", terminator: "")
                linesPrinted = 0
            }
        }

        // Print final summary lines.
        for f in files {
            let totalStr = Self.formatBytes(f.expectedBytes > 0 ? f.expectedBytes : f.downloadedBytes)
            let elapsed = (f.completionTime ?? Date()).timeIntervalSince(f.startTime)
            let avgSpeed = elapsed > 0.1 ? Double(max(0, f.downloadedBytes - f.baselineBytes)) / elapsed : 0
            let speedStr = Self.formatSpeed(avgSpeed)
            let timeStr = Self.formatDuration(elapsed)
            print("  \u{2713} \(f.label)  \(totalStr)  \(speedStr)  \(timeStr)")
        }
    }

    // MARK: - ANSI rendering

    private func renderANSI(_ files: [FileProgress]) {
        // Move cursor up to overwrite previous render.
        if linesPrinted > 0 {
            print("\u{1B}[\(linesPrinted)A", terminator: "")
        }

        let termWidth = Self.terminalWidth()
        var lines = 0
        for f in files {
            print("\u{1B}[2K", terminator: "")  // Clear the line
            let line = Self.formatLine(f, termWidth: termWidth)
            print(line)
            lines += 1
        }
        linesPrinted = lines
        fflush(stdout)
    }

    private func renderPlain(_ files: [FileProgress]) {
        for f in files where f.completed && !printedLabels.contains(f.label) {
            printedLabels.insert(f.label)
            let totalStr = Self.formatBytes(f.expectedBytes > 0 ? f.expectedBytes : f.downloadedBytes)
            print("  \u{2713} \(f.label)  \(totalStr)")
        }
    }

    // MARK: - Line formatting

    private static func formatLine(_ f: FileProgress, termWidth: Int) -> String {
        if f.completed {
            let totalStr = formatBytes(f.expectedBytes > 0 ? f.expectedBytes : f.downloadedBytes)
            let elapsed = (f.completionTime ?? Date()).timeIntervalSince(f.startTime)
            let avgSpeed = elapsed > 0.1 ? Double(max(0, f.downloadedBytes - f.baselineBytes)) / elapsed : 0
            return "  \u{2713} \(f.label)  \(totalStr)  \(formatSpeed(avgSpeed))  done"
        }

        let pct = Int(f.fraction * 100)
        let dlStr = formatBytes(f.downloadedBytes)
        let totStr = formatBytes(f.expectedBytes)
        let speedStr = formatSpeed(f.speed)
        let etaStr: String
        if let eta = f.eta {
            etaStr = "ETA \(formatDuration(eta))"
        } else {
            etaStr = "---"
        }

        // Assemble the suffix: "  62%  2.1/4.8 GB  113 MB/s  ETA 24s"
        let suffix = "  \(String(format: "%3d", pct))%  \(dlStr)/\(totStr)  \(speedStr)  \(etaStr)"

        // Calculate bar width: total - label - prefix - suffix - brackets - spaces
        let labelMaxWidth = min(f.label.count, 45)
        let label = f.label.count > labelMaxWidth
            ? String(f.label.suffix(labelMaxWidth - 1)).padding(toLength: labelMaxWidth, withPad: " ", startingAt: 0)
            : f.label
        let prefix = "  \(label)  ["
        let postfix = "]\(suffix)"
        let barWidth = max(10, termWidth - prefix.count - postfix.count)

        let filled = Int(f.fraction * Double(barWidth))
        let empty = barWidth - filled
        let bar = String(repeating: "\u{2588}", count: filled) + String(repeating: "\u{2591}", count: empty)

        return "\(prefix)\(bar)\(postfix)"
    }

    // MARK: - Formatting helpers

    static func formatBytes(_ bytes: Int64) -> String {
        let b = Double(bytes)
        if b < 1024 { return "\(bytes) B" }
        if b < 1_048_576 { return String(format: "%.1f KB", b / 1024) }
        if b < 1_073_741_824 { return String(format: "%.1f MB", b / 1_048_576) }
        return String(format: "%.1f GB", b / 1_073_741_824)
    }

    static func formatSpeed(_ bytesPerSec: Double) -> String {
        if bytesPerSec < 1024 { return String(format: "%.0f B/s", bytesPerSec) }
        if bytesPerSec < 1_048_576 { return String(format: "%.0f KB/s", bytesPerSec / 1024) }
        if bytesPerSec < 1_073_741_824 { return String(format: "%.0f MB/s", bytesPerSec / 1_048_576) }
        return String(format: "%.1f GB/s", bytesPerSec / 1_073_741_824)
    }

    static func formatDuration(_ seconds: Double) -> String {
        let s = Int(seconds)
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m \(s % 60)s" }
        return "\(s / 3600)h \(s / 60 % 60)m"
    }

    static func terminalWidth() -> Int {
        #if canImport(Darwin)
        var w = winsize()
        if ioctl(STDOUT_FILENO, TIOCGWINSZ, &w) == 0, w.ws_col > 0 {
            return Int(w.ws_col)
        }
        #endif
        return 80
    }
}
