import Foundation

/// One line showing how far a transfer of known size is: its label, a bar, the
/// percent, the bytes on disk, the rate and the time left.
///
///     Downloading EigenLabs/Qwen3.8-27B-4bit-mtp  [██████░░░░░░░░]  43%  7.0/16.3 GB  125 MB/s  1m 14s left
///
/// Model downloads in the CLI (`DownloadProgressRenderer`) and the cluster
/// setup's downloads and cable copies show it. It is pure: the caller passes
/// every time, in seconds on one monotonic clock, and the width. The rate counts
/// only the bytes that arrived after `startBytes`, so a resumed transfer is not
/// credited with what was already on disk.
struct TransferProgressLine: Sendable {
    /// A terminal redraws the line at most this often.
    static let redrawInterval: TimeInterval = 0.25
    /// Where the line cannot be redrawn, it is written again only once this
    /// long and `logPercentStep` points have passed since the last one.
    static let logInterval: TimeInterval = 30
    static let logPercentStep = 10

    static let minimumLabelWidth = 24
    static let minimumBarWidth = 10
    static let maximumBarWidth = 30

    let label: String
    let totalBytes: Int64
    let startBytes: Int64
    let startTime: TimeInterval
    private var lastRedraw: TimeInterval?
    private var lastLog: (time: TimeInterval, percent: Int)?

    init(label: String, totalBytes: Int64, startBytes: Int64, startTime: TimeInterval) {
        self.label = label
        self.totalBytes = totalBytes
        self.startBytes = startBytes
        self.startTime = startTime
    }

    func fraction(done: Int64) -> Double {
        guard totalBytes > 0 else { return 0 }
        return Double(min(max(done, 0), totalBytes)) / Double(totalBytes)
    }

    /// Rounded down, so 100% means every byte is there.
    func percent(done: Int64) -> Int { Int(fraction(done: done) * 100) }

    /// Bytes per second since the start; nil until time passed and bytes arrived.
    func bytesPerSecond(done: Int64, now: TimeInterval) -> Double? {
        let elapsed = now - startTime
        let arrived = done - startBytes
        guard elapsed > 0, arrived > 0 else { return nil }
        return Double(arrived) / elapsed
    }

    /// Whether a terminal redraw is due at `now`. A due redraw is recorded.
    mutating func takeRedraw(now: TimeInterval) -> Bool {
        if let lastRedraw, now - lastRedraw < Self.redrawInterval { return false }
        lastRedraw = now
        return true
    }

    /// Whether a line for a log is due at `now`: the first one, then one once
    /// both `logInterval` and `logPercentStep` have passed since the last,
    /// whichever comes later. When the transfer `ended`, one is due unless the
    /// last one already showed this percent. A due line is recorded.
    mutating func takeLogLine(done: Int64, now: TimeInterval, ended: Bool = false) -> Bool {
        let percent = percent(done: done)
        if let lastLog {
            let due = ended
                ? percent != lastLog.percent
                : now - lastLog.time >= Self.logInterval && percent - lastLog.percent >= Self.logPercentStep
            guard due else { return false }
        }
        lastLog = (now, percent)
        return true
    }

    /// The line laid out in at most `width` columns, or without a width the
    /// plain form for logs and transcripts: the same figures, no bar.
    func text(done: Int64, now: TimeInterval, width: Int? = nil) -> String {
        let rate = bytesPerSecond(done: done, now: now)
        let remaining = totalBytes - done
        let figures = Figures(
            percent: "\(percent(done: done))%",
            bytes: Self.bytes(done, of: totalBytes),
            rate: rate.map(Self.rate),
            timeLeft: rate.flatMap { remaining > 0 ? Self.duration(Double(remaining) / $0) + " left" : nil })
        guard let width else {
            return ([label, figures.percent, figures.bytes] + [figures.rate, figures.timeLeft].compactMap { $0 })
                .joined(separator: "  ")
        }
        return layOut(figures, fraction: fraction(done: done), width: width)
    }

    // MARK: - Layout

    private struct Figures {
        let percent: String
        let bytes: String
        let rate: String?
        let timeLeft: String?
    }

    private struct Layout {
        var labelWidth: Int
        var barWidth: Int?
        var showsTimeLeft = false
        var showsBytes = false
        var showsRate = false
    }

    /// The percent always shows. Then, while they fit and in this order: the
    /// start of the label, a bar of `minimumBarWidth` cells, the time left,
    /// the rest of the label, the bytes, the rate, and a wider bar. Whatever is
    /// left out, the shown parts keep their order on the line.
    private func layOut(_ figures: Figures, fraction: Double, width: Int) -> String {
        // Padded so the figures after it do not shift when it reaches 10%.
        let percent = String(repeating: " ", count: max(0, 3 - figures.percent.count)) + figures.percent
        func parts(_ layout: Layout) -> [String] {
            var parts = [Self.clipped(label, to: layout.labelWidth)]
            if let cells = layout.barWidth {
                let filled = min(cells, Int(fraction * Double(cells)))
                parts.append("[" + String(repeating: "\u{2588}", count: filled)
                    + String(repeating: "\u{2591}", count: cells - filled) + "]")
            }
            parts.append(percent)
            if layout.showsBytes { parts.append(figures.bytes) }
            if layout.showsRate, let rate = figures.rate { parts.append(rate) }
            if layout.showsTimeLeft, let timeLeft = figures.timeLeft { parts.append(timeLeft) }
            return parts
        }
        func length(_ layout: Layout) -> Int {
            let parts = parts(layout)
            return parts.reduce(0) { $0 + $1.count } + 2 * (parts.count - 1)
        }
        var layout = Layout(labelWidth: min(label.count, Self.minimumLabelWidth), barWidth: Self.minimumBarWidth)
        if length(layout) > width { layout.barWidth = nil }
        func add(_ change: (inout Layout) -> Void) {
            var wider = layout
            change(&wider)
            if length(wider) <= width { layout = wider }
        }
        if figures.timeLeft != nil { add { $0.showsTimeLeft = true } }
        // The label takes the room left, or gives some up when even its start does not fit.
        layout.labelWidth = max(1, min(label.count, layout.labelWidth + width - length(layout)))
        add { $0.showsBytes = true }
        if figures.rate != nil { add { $0.showsRate = true } }
        if let cells = layout.barWidth {
            layout.barWidth = min(Self.maximumBarWidth, cells + max(0, width - length(layout)))
        }
        return Self.clipped(parts(layout).joined(separator: "  "), to: max(0, width))
    }

    // MARK: - Formatting

    /// `text` itself, or its start and an ellipsis in `width` characters.
    static func clipped(_ text: String, to width: Int) -> String {
        guard text.count > width else { return text }
        guard width > 0 else { return "" }
        return text.prefix(width - 1) + "\u{2026}"
    }

    /// "16.3 GB", "512.0 MB", "40 KB", "900 B": decimal units, as the catalog
    /// gives model sizes.
    static func bytes(_ count: Int64) -> String {
        let unit = unit(for: count)
        return unit.number(count) + " " + unit.name
    }

    /// "7.0/16.3 GB": both in the unit of the total.
    static func bytes(_ done: Int64, of total: Int64) -> String {
        let unit = unit(for: total)
        return unit.number(done) + "/" + unit.number(total) + " " + unit.name
    }

    /// "125 MB/s", "2.4 GB/s".
    static func rate(_ bytesPerSecond: Double) -> String {
        switch bytesPerSecond {
        case 1e9...: return String(format: "%.1f GB/s", bytesPerSecond / 1e9)
        case 1e6...: return String(format: "%.0f MB/s", bytesPerSecond / 1e6)
        case 1e3...: return String(format: "%.0f KB/s", bytesPerSecond / 1e3)
        default: return String(format: "%.0f B/s", bytesPerSecond)
        }
    }

    /// "45s", "1m 14s", "2h 5m".
    static func duration(_ seconds: Double) -> String {
        DurationFormatting.compact(seconds, secondsInMinuteRange: true, elideZeroMinutesInHourRange: false)
    }

    private struct ByteUnit {
        let divisor: Double
        let name: String
        let decimals: Int

        func number(_ bytes: Int64) -> String {
            String(format: "%.\(decimals)f", Double(bytes) / divisor)
        }
    }

    private static func unit(for bytes: Int64) -> ByteUnit {
        switch bytes {
        case 1_000_000_000...: return ByteUnit(divisor: 1e9, name: "GB", decimals: 1)
        case 1_000_000...: return ByteUnit(divisor: 1e6, name: "MB", decimals: 1)
        case 1_000...: return ByteUnit(divisor: 1e3, name: "KB", decimals: 0)
        default: return ByteUnit(divisor: 1, name: "B", decimals: 0)
        }
    }
}
