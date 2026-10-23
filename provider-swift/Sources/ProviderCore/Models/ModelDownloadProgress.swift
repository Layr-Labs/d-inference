/// Download progress tracking + terminal rendering for the foreground model
/// download path (`darkbloom models download` / the interactive picker).
///
/// Split out of `ModelCatalog.swift` so that file stays focused on catalog +
/// download orchestration. The tracker here is callback-driven (fed by the
/// streaming, byte-resumable downloader in `ModelDownloader+HTTP.swift`) rather
/// than a `URLSessionDownloadDelegate`: downloads now stream straight to a
/// `.part` file for true byte-level resume, so there is no
/// `URLSessionDownloadTask` to observe — progress arrives as
/// cumulative-bytes-on-disk callbacks instead.

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
    /// Bytes already on disk when this transfer started (a resumed `.part`
    /// prefix). Excluded from the speed/ETA math so a resume doesn't report an
    /// inflated instantaneous rate for bytes it never actually transferred.
    var baselineBytes: Int64 = 0
    /// When this transfer started. Every pending file is registered up front
    /// but only a few transfer at once, so `ManifestDownloadProgress.start`
    /// restarts the clock: time spent queued must not dilute the rate.
    var startTime: Date = Date()
    /// Whether the transfer has begun. Queued files get no live row.
    var started: Bool = false
    var completed: Bool = false
    var completionTime: Date?

    /// Bytes/second over this transfer (excludes the resumed prefix).
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

    /// Mark a file's transfer as starting now, restarting its rate clock.
    func start(label: String) {
        lock.lock()
        defer { lock.unlock() }
        guard var p = progress[label] else { return }
        p.started = true
        p.startTime = Date()
        p.baselineBytes = p.downloadedBytes
        progress[label] = p
    }

    /// Update cumulative bytes-on-disk for a file.
    func update(label: String, downloadedBytes: Int64) {
        lock.lock()
        defer { lock.unlock() }
        guard var p = progress[label] else { return }
        if downloadedBytes == 0 || downloadedBytes < p.downloadedBytes {
            // A report of zero or of fewer bytes means the `.part` was discarded
            // and the transfer restarted (e.g. the Hugging Face to R2 fallback,
            // even before any byte arrived, or a checksum retry). Time the
            // restarted transfer on its own so the rate stays honest.
            p.baselineBytes = downloadedBytes
            p.startTime = Date()
        }
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

/// Renders download progress to the terminal.
///
/// On a TTY it redraws a block of live rows in place: one bar per in-flight
/// file plus, for multi-file downloads, a total row. Each frame moves the
/// cursor back up over the previous block, and terminals clamp that movement
/// at the top of the visible screen. The block is therefore limited to the
/// terminal height and every row to its width: a taller block (one row per
/// shard of a many-file model) or a wrapped row would leave a partial copy in
/// the scrollback on every frame and scroll forever. Each file is instead
/// logged once, above the block, when it completes. Without a TTY only those
/// completion lines are printed.
final class ProgressRenderer: @unchecked Sendable {

    struct TerminalSize: Equatable, Sendable {
        let columns: Int
        let rows: Int
    }

    /// Longer labels are shortened by `shortenedLabel`.
    private static let maxLabelWidth = 45
    /// Labels are shortened no further than this before columns are dropped.
    private static let compactLabelWidth = 20
    /// Labels give up width until the bar is this wide.
    private static let preferredBarWidth = 20
    /// Bars stop growing here on wide terminals.
    private static let maximumBarWidth = 40
    /// A narrower bar is dropped rather than letting the row wrap.
    private static let minimumBarWidth = 10

    private let isTTY: Bool
    private let terminalSize: @Sendable () -> TerminalSize
    private let output: @Sendable (String) -> Void
    private let lock = NSLock()
    /// Rows drawn by the previous frame's live block. The cursor is parked on
    /// the row just below it.
    private var liveRowCount = 0
    /// Files whose completion line has been printed.
    private var loggedCompletions: Set<String> = []

    init(
        isTTY: Bool = isatty(STDOUT_FILENO) != 0,
        terminalSize: @escaping @Sendable () -> TerminalSize = ProgressRenderer.currentTerminalSize,
        output: @escaping @Sendable (String) -> Void = ProgressRenderer.writeToStandardOutput
    ) {
        self.isTTY = isTTY
        self.terminalSize = terminalSize
        self.output = output
    }

    /// Render a frame given the current file progress snapshot.
    func render(_ files: [FileProgress]) {
        lock.lock()
        defer { lock.unlock() }
        let size = isTTY ? terminalSize() : nil
        var frame = eraseLiveRows() + completionLines(files, width: size.map { $0.columns - 1 })
        if let size {
            let rows = liveRows(files, size: size)
            frame += rows.map { $0 + "\n" }.joined()
            liveRowCount = rows.count
        }
        emit(frame)
    }

    /// Final render: clear the live rows and log the completions not yet
    /// printed.
    func finish(_ files: [FileProgress]) {
        lock.lock()
        defer { lock.unlock() }
        let width = isTTY ? terminalSize().columns - 1 : nil
        emit(eraseLiveRows() + completionLines(files, width: width))
    }

    // MARK: - Frame composition

    /// Return to the first row of the previous live block and clear it and
    /// everything below. The block fits on screen, so the cursor-up lands on
    /// that row instead of being clamped short of it; the carriage return
    /// discards any column offset from keys echoed on the cursor row.
    private func eraseLiveRows() -> String {
        guard liveRowCount > 0 else { return "" }
        let erase = "\u{1B}[\(liveRowCount)A\r\u{1B}[J"
        liveRowCount = 0
        return erase
    }

    /// A permanent line for each newly completed file, in registration order.
    private func completionLines(_ files: [FileProgress], width: Int?) -> String {
        let labelWidth = min(Self.maxLabelWidth, files.map(\.label.count).max() ?? 0)
        var lines = ""
        for f in files where f.completed && !loggedCompletions.contains(f.label) {
            loggedCompletions.insert(f.label)
            lines += Self.completionLine(f, labelWidth: labelWidth, width: width) + "\n"
        }
        return lines
    }

    /// One bar per in-flight file, then the total row, limited to `rows - 1`
    /// so the parked cursor stays on screen. Queued files appear only in the
    /// total. Rows leave the last column free so a narrowing resize does not
    /// rewrap them.
    private func liveRows(_ files: [FileProgress], size: TerminalSize) -> [String] {
        guard size.rows > 1 else { return [] }
        let capacity = size.rows - 1
        let inFlight = files.filter { $0.started && !$0.completed }
        let rows: [FileProgress] = files.count > 1
            ? Array(inFlight.prefix(capacity - 1)) + [Self.aggregate(files)]
            : Array(inFlight.prefix(capacity))
        return Self.layOut(rows, allLabels: files.map(\.label) + rows.map(\.label), width: size.columns - 1)
    }

    private func emit(_ text: String) {
        guard !text.isEmpty else { return }
        output(text)
    }

    // MARK: - Live row layout

    /// The text of one live row's columns.
    private struct RowCells {
        var label = ""
        var fraction = 0.0
        var percent = ""
        var done = ""
        var total = ""
        var rate = ""
        var eta = ""

        init() {}

        init(_ f: FileProgress) {
            label = f.label
            fraction = f.fraction
            percent = String(format: "%3d%%", Int(f.fraction * 100))
            done = ProgressRenderer.formatBytes(f.downloadedBytes)
            total = ProgressRenderer.formatBytes(f.expectedBytes)
            rate = ProgressRenderer.formatSpeed(f.speed)
            eta = f.eta.map { "ETA \(ProgressRenderer.formatDuration($0))" } ?? "---"
        }
    }

    /// Lay out one frame's rows on shared fixed-width columns no wider than
    /// `width`, so bars and figures line up and stay put between frames. Labels
    /// give up width (down to `compactLabelWidth`) before the bar drops below
    /// `preferredBarWidth`; when even that leaves too little, the rate column
    /// goes, then the bar, and rows are clipped as a last resort.
    static func layOut(_ rows: [FileProgress], allLabels: [String], width: Int) -> [String] {
        let cells = rows.map(RowCells.init)
        let naturalLabelWidth = min(maxLabelWidth, allLabels.map(\.count).max() ?? 0)
        // Sized from every label, not just this frame's, so the bars stay put
        // as different files come and go.
        func labelColumn(limit: Int) -> Int {
            allLabels.map { shortenedLabel($0, width: limit).count }.max() ?? 0
        }
        for (showsRate, minimumBar) in [(true, 12), (false, minimumBarWidth)] {
            let room = width - row(RowCells(), labelWidth: 0, barWidth: 0, showsRate: showsRate).count
            let labelWidth = labelColumn(
                limit: min(naturalLabelWidth, max(compactLabelWidth, room - preferredBarWidth)))
            let barWidth = min(maximumBarWidth, room - labelWidth)
            if barWidth >= minimumBar {
                return cells.map {
                    clipped(row($0, labelWidth: labelWidth, barWidth: barWidth, showsRate: showsRate), to: width)
                }
            }
        }
        let labelWidth = labelColumn(limit: min(naturalLabelWidth, compactLabelWidth))
        return cells.map { clipped(row($0, labelWidth: labelWidth, barWidth: nil, showsRate: false), to: width) }
    }

    /// `    label  [████░░░░]   62%     2.1 GB/4.8 GB      113 MB/s  ETA 24s`
    private static func row(_ c: RowCells, labelWidth: Int, barWidth: Int?, showsRate: Bool) -> String {
        var row = "    " + padded(shortenedLabel(c.label, width: labelWidth), to: labelWidth)
        if let barWidth {
            let filled = Int(c.fraction * Double(barWidth))
            row += "  [" + String(repeating: "\u{2588}", count: filled)
                + String(repeating: "\u{2591}", count: barWidth - filled) + "]"
        }
        row += "  " + padded(c.percent, to: 4, leading: true)
        row += "  " + padded(c.done, to: 9, leading: true) + "/" + padded(c.total, to: 9)
        if showsRate { row += "  " + padded(c.rate, to: 9, leading: true) }
        return row + "  " + padded(c.eta, to: 11)
    }

    /// Every file as one progress value labelled with the completed count. Its
    /// rate is the combined transfer since the first file started.
    static func aggregate(_ files: [FileProgress]) -> FileProgress {
        let completed = files.filter(\.completed).count
        var total = FileProgress(
            label: "total \(completed)/\(files.count) files",
            expectedBytes: files.reduce(0) { $0 + $1.expectedBytes })
        total.downloadedBytes = files.reduce(0) { $0 + $1.downloadedBytes }
        total.baselineBytes = files.reduce(0) { $0 + $1.baselineBytes }
        total.startTime = files.filter(\.started).map(\.startTime).min() ?? Date()
        return total
    }

    /// The label, or a shorter form no wider than `width`: first without its
    /// file extension, then its tail behind an ellipsis. Shard numbers sit at
    /// the end of the name, just before the extension.
    static func shortenedLabel(_ label: String, width: Int) -> String {
        guard label.count > width else { return label }
        let stem = (label as NSString).deletingPathExtension
        guard stem.count > width else { return stem }
        guard width > 1 else { return String(stem.suffix(max(0, width))) }
        return "\u{2026}" + stem.suffix(width - 1)
    }

    // MARK: - Completion lines

    /// `  ✓ label  size  rate  elapsed` in aligned columns, or unaligned when the
    /// aligned line would not fit the terminal.
    private static func completionLine(_ f: FileProgress, labelWidth: Int, width: Int?) -> String {
        let size = formatBytes(f.expectedBytes > 0 ? f.expectedBytes : f.downloadedBytes)
        let rate = formatSpeed(f.speed)
        let elapsed = formatDuration((f.completionTime ?? Date()).timeIntervalSince(f.startTime))
        let aligned = "  \u{2713} " + padded(f.label, to: labelWidth)
            + "  " + padded(size, to: 9, leading: true)
            + "  " + padded(rate, to: 9, leading: true)
            + "  " + padded(elapsed, to: 7, leading: true)
        guard let width, aligned.count > width else { return aligned }
        return "  \u{2713} \(f.label)  \(size)  \(rate)  \(elapsed)"
    }

    // MARK: - Formatting helpers

    private static func padded(_ text: String, to width: Int, leading: Bool = false) -> String {
        let padding = String(repeating: " ", count: max(0, width - text.count))
        return leading ? padding + text : text + padding
    }

    private static func clipped(_ text: String, to width: Int) -> String {
        text.count <= width ? text : String(text.prefix(max(0, width)))
    }

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
        DurationFormatting.compact(
            seconds,
            secondsInMinuteRange: true,
            elideZeroMinutesInHourRange: false
        )
    }

    // MARK: - Terminal

    static func currentTerminalSize() -> TerminalSize {
        #if canImport(Darwin)
        var w = winsize()
        if ioctl(STDOUT_FILENO, TIOCGWINSZ, &w) == 0, w.ws_col > 0, w.ws_row > 0 {
            return TerminalSize(columns: Int(w.ws_col), rows: Int(w.ws_row))
        }
        #endif
        return TerminalSize(columns: 80, rows: 24)
    }

    /// Write a frame with as few `write(2)` calls as possible (normally one):
    /// line-buffered `print` would flush every row separately, and a screen
    /// refresh between those writes shows the block half drawn.
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
