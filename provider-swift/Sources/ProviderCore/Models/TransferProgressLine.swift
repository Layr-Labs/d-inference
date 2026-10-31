import Foundation

/// One line showing how far a transfer of known size is: its label, a bar, the
/// percent, the bytes on disk, the rate and the time left.
///
///     Downloading EigenLabs/Qwen3.8-27B-4bit-mtp  [██████░░░░░░░░]   43%   7.0/16.3 GB   125 MB/s   1m 14s left
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
    /// The rate and the time left wait this long after the start: the first
    /// moments of a transfer say little about the rest of it.
    static let estimateDelay: TimeInterval = 2
    /// A longer time left is not shown.
    static let maximumTimeLeft: TimeInterval = 24 * 60 * 60
    /// A faster rate is shown as this one, so the rate has a widest form.
    static let maximumRate = 99.9e9

    static let minimumLabelWidth = 24
    static let minimumBarWidth = 10
    static let maximumBarWidth = 30

    /// Where the parts of the line go in `width` columns: the label's and the
    /// bar's widths and the figures that have a column. It comes from each
    /// figure's widest form for this transfer, never from the figures of the
    /// moment, so every redraw at one width has the same shape.
    struct Layout: Equatable, Sendable {
        let width: Int
        let labelWidth: Int
        let barWidth: Int?
        let showsBytes: Bool
        let showsRate: Bool
        let showsTimeLeft: Bool
    }

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

    /// Bytes per second since the start, once `estimateDelay` has passed and
    /// bytes have arrived; nil before.
    func bytesPerSecond(done: Int64, now: TimeInterval) -> Double? {
        let elapsed = now - startTime
        let arrived = done - startBytes
        guard elapsed >= Self.estimateDelay, arrived > 0 else { return nil }
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
    /// whichever comes later. When the transfer `ended`, one is due if lines
    /// came before and none showed this percent; with none before, nothing
    /// was transferred to show. A due line is recorded.
    mutating func takeLogLine(done: Int64, now: TimeInterval, ended: Bool = false) -> Bool {
        let percent = percent(done: done)
        if let lastLog {
            let due = ended
                ? percent != lastLog.percent
                : now - lastLog.time >= Self.logInterval && percent - lastLog.percent >= Self.logPercentStep
            guard due else { return false }
        } else if ended {
            return false
        }
        lastLog = (now, percent)
        return true
    }

    /// The line in at most `width` columns, laid out by `layout(width:)`, or
    /// without a width the plain form for logs and transcripts: the figures of
    /// the moment, no bar and no padding.
    func text(done: Int64, now: TimeInterval, width: Int? = nil) -> String {
        guard let width else {
            let figures = figures(done: done, now: now)
            return ([label, figures.percent, figures.bytes] + [figures.rate, figures.timeLeft].compactMap { $0 })
                .joined(separator: "  ")
        }
        return text(done: done, now: now, layout: layout(width: width))
    }

    /// The line in `layout`'s columns: each figure right-aligned in the column
    /// its widest form needs, a figure not known yet left blank, and blanks at
    /// the end of the line trimmed.
    func text(done: Int64, now: TimeInterval, layout: Layout) -> String {
        let figures = figures(done: done, now: now)
        let widest = widest
        func column(_ figure: String?, _ width: Int) -> String {
            let figure = figure ?? ""
            return String(repeating: " ", count: max(0, width - figure.count)) + figure
        }
        var parts = [Self.clipped(label, to: layout.labelWidth)]
        if let cells = layout.barWidth {
            let filled = min(cells, Int(fraction(done: done) * Double(cells)))
            parts.append("[" + String(repeating: "\u{2588}", count: filled)
                + String(repeating: "\u{2591}", count: cells - filled) + "]")
        }
        parts.append(column(figures.percent, widest.percent))
        if layout.showsBytes { parts.append(column(figures.bytes, widest.bytes)) }
        if layout.showsRate { parts.append(column(figures.rate, widest.rate)) }
        if layout.showsTimeLeft { parts.append(column(figures.timeLeft, widest.timeLeft)) }
        var line = parts.joined(separator: "  ")
        while line.last == " " { line.removeLast() }
        return Self.clipped(line, to: max(0, layout.width))
    }

    /// The percent always has a column. Then, while they fit at their widest
    /// and in this order: the start of the label, a bar of `minimumBarWidth`
    /// cells, the time left, the rest of the label, the bytes, the rate, and a
    /// wider bar. Whatever is left out, the parts keep their order on the line.
    func layout(width: Int) -> Layout {
        let widest = widest
        var labelWidth = min(label.count, Self.minimumLabelWidth)
        var barWidth: Int? = Self.minimumBarWidth
        var showsBytes = false, showsRate = false, showsTimeLeft = false
        func length() -> Int {
            var columns = [labelWidth, widest.percent]
            if let barWidth { columns.append(barWidth + 2) }
            if showsBytes { columns.append(widest.bytes) }
            if showsRate { columns.append(widest.rate) }
            if showsTimeLeft { columns.append(widest.timeLeft) }
            return columns.reduce(0, +) + 2 * (columns.count - 1)
        }
        if length() > width { barWidth = nil }
        showsTimeLeft = true
        if length() > width { showsTimeLeft = false }
        // The label takes the room left, or gives some up when even its start does not fit.
        labelWidth = max(1, min(label.count, labelWidth + width - length()))
        showsBytes = true
        if length() > width { showsBytes = false }
        showsRate = true
        if length() > width { showsRate = false }
        if let cells = barWidth { barWidth = min(Self.maximumBarWidth, cells + max(0, width - length())) }
        return Layout(width: width, labelWidth: labelWidth, barWidth: barWidth,
                      showsBytes: showsBytes, showsRate: showsRate, showsTimeLeft: showsTimeLeft)
    }

    // MARK: - Figures

    private struct Figures {
        let percent: String
        let bytes: String
        let rate: String?
        let timeLeft: String?
    }

    private func figures(done: Int64, now: TimeInterval) -> Figures {
        let onDisk = min(max(done, 0), totalBytes)
        let rate = bytesPerSecond(done: done, now: now)
        let secondsLeft = rate.map { Double(totalBytes - onDisk) / $0 }
        let timeLeft = secondsLeft.flatMap { $0 > 0 && $0 <= Self.maximumTimeLeft ? Self.duration($0) + " left" : nil }
        return Figures(percent: "\(percent(done: done))%", bytes: Self.bytes(onDisk, of: totalBytes),
                       rate: rate.map(Self.rate), timeLeft: timeLeft)
    }

    /// The widths of each figure's widest form for this transfer.
    private var widest: (percent: Int, bytes: Int, rate: Int, timeLeft: Int) {
        ("100%".count, Self.bytes(totalBytes, of: totalBytes).count, Self.widestRate, Self.widestTimeLeft)
    }

    private static let widestRate = [999, 999e3, 999e6, maximumRate].map { rate($0).count }.max() ?? 0
    private static let widestTimeLeft = [59, 3_599, maximumTimeLeft - 1, maximumTimeLeft]
        .map { (duration($0) + " left").count }.max() ?? 0

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

    /// "125 MB/s", "2.4 GB/s". Each unit stops below the rounding into the
    /// next one ("1.0 GB/s", never "1000 MB/s"), and `maximumRate` caps it.
    static func rate(_ bytesPerSecond: Double) -> String {
        let rate = min(bytesPerSecond, maximumRate)
        switch rate {
        case 999.5e6...: return String(format: "%.1f GB/s", rate / 1e9)
        case 999.5e3...: return String(format: "%.0f MB/s", rate / 1e6)
        case 999.5...: return String(format: "%.0f KB/s", rate / 1e3)
        default: return String(format: "%.0f B/s", rate)
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
