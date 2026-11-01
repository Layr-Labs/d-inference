import Crypto
import Foundation
import Testing

@testable import ProviderCore

/// Everything a renderer writes, one chunk per write.
private final class CapturedOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var writes: [String] = []

    func append(_ chunk: String) { lock.withLock { writes.append(chunk) } }

    var value: String { lock.withLock { writes.joined() } }

    /// The lines of output that is not a terminal.
    var lines: [String] { value.split(separator: "\n").map(String.init) }
}

/// The renderer's clock, moved by hand.
private final class ManualClock: @unchecked Sendable {
    private let lock = NSLock()
    private var seconds: TimeInterval = 1_000

    var now: TimeInterval { lock.withLock { seconds } }

    func advance(_ interval: TimeInterval) { lock.withLock { seconds += interval } }
}

/// The renderer's window width, changed by hand.
private final class WindowWidth: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int

    init(_ columns: Int) { value = columns }

    var columns: Int { lock.withLock { value } }

    func resize(to columns: Int) { lock.withLock { value = columns } }
}

/// A VT100 screen model covering what the renderer may emit: printable text
/// with deferred auto-wrap, LF (with the tty's carriage return), CR and
/// `ESC[K`. Any other control sequence fails the test. Rows that scroll off
/// the top accumulate in `scrollback`.
private struct VirtualTerminal {
    let columns: Int
    let rows: Int
    private(set) var screen: [[Character]]
    private(set) var scrollback: [String] = []
    private var row = 0
    private var column = 0
    private var wrapPending = false

    init(columns: Int, rows: Int = 24) {
        self.columns = columns
        self.rows = rows
        screen = Array(repeating: Array(repeating: " ", count: columns), count: rows)
    }

    /// Non-blank visible rows, trailing blanks trimmed.
    var visibleLines: [String] { screen.map(Self.trimmed).filter { !$0.isEmpty } }

    /// Every non-blank row ever displayed, oldest first.
    var transcript: [String] { scrollback.filter { !$0.isEmpty } + visibleLines }

    mutating func feed(_ text: String) {
        var scalars = Array(text.unicodeScalars)[...]
        while let scalar = scalars.popFirst() {
            switch scalar {
            case "\u{1B}":
                guard scalars.popFirst() == "[", scalars.popFirst() == "K" else {
                    Issue.record("a control sequence other than ESC[K")
                    return
                }
                for cell in column..<columns { screen[row][cell] = " " }
            case "\n":
                lineFeed()
                column = 0
                wrapPending = false
            case "\r":
                column = 0
                wrapPending = false
            default:
                if wrapPending {
                    lineFeed()
                    column = 0
                    wrapPending = false
                }
                screen[row][column] = Character(scalar)
                if column == columns - 1 { wrapPending = true } else { column += 1 }
            }
        }
    }

    private mutating func lineFeed() {
        guard row == rows - 1 else {
            row += 1
            return
        }
        scrollback.append(Self.trimmed(screen.removeFirst()))
        screen.append(Array(repeating: " ", count: columns))
    }

    private static func trimmed(_ cells: [Character]) -> String {
        var line = String(cells)
        while line.last == " " { line.removeLast() }
        return line
    }
}

@Suite("Model download progress line")
struct ModelDownloadProgressTests {
    private static let modelID = "EigenLabs/Qwen3.8-27B-4bit-mtp"
    private static let total: Int64 = 16_300_000_000
    /// 7.02 GB of 16.3 GB, 56.16 s after starting from nothing: 43%, 125 MB/s, 74 s left.
    private static let done: Int64 = 7_020_000_000
    private static let now: TimeInterval = 1_056.16

    private static func line(startBytes: Int64 = 0) -> TransferProgressLine {
        TransferProgressLine(label: "Downloading \(modelID)", totalBytes: total, startBytes: startBytes, startTime: 1_000)
    }

    private static func bar(filled: Int, of cells: Int) -> String {
        "[" + String(repeating: "\u{2588}", count: filled) + String(repeating: "\u{2591}", count: cells - filled) + "]"
    }

    // MARK: - The line

    @Test("each figure that fits at its widest gets a column, right-aligned in it")
    func layoutByWidth() {
        let line = Self.line()
        // "100%", "16.3/16.3 GB", "99.9 GB/s" and "23h 59m left" size the columns.
        #expect(line.text(done: Self.done, now: Self.now, width: 131)
            == "Downloading \(Self.modelID)  \(Self.bar(filled: 12, of: 30))   43%   7.0/16.3 GB   125 MB/s   1m 14s left")
        #expect(line.text(done: Self.done, now: Self.now, width: 99)
            == "Downloading \(Self.modelID)  \(Self.bar(filled: 8, of: 19))   43%   7.0/16.3 GB   1m 14s left")
        // An 80-column window (77 columns after the indent and the last column)
        // keeps the whole label and the time left, without the bytes and the rate.
        #expect(line.text(done: Self.done, now: Self.now, width: 77)
            == "Downloading \(Self.modelID)  \(Self.bar(filled: 4, of: 11))   43%   1m 14s left")
    }

    @Test("a laid-out line never passes its width and keeps the percent while there is room",
          arguments: [131, 99, 77, 60, 44, 43, 30, 20, 10, 7, 6, 1, 0])
    func layoutFitsWidth(width: Int) {
        let text = Self.line().text(done: Self.done, now: Self.now, width: width)
        #expect(text.count <= width)
        #expect(text.contains("43%") == (width >= 7))
        #expect(text.contains("[") == (width >= 44))
    }

    @Test("the layout depends on the width only, not on the figures of the moment")
    func layoutIsTheWidths() {
        let line = Self.line()
        func column(of character: Character, in text: String) -> Int? {
            text.firstIndex(of: character).map { text.distance(from: text.startIndex, to: $0) }
        }
        for width in [57, 77, 97, 117] {
            // Before there is a rate, and later with every figure at a different length.
            let first = line.text(done: 0, now: 1_000, width: width)
            let later = line.text(done: Self.done, now: Self.now, width: width)
            #expect(column(of: "]", in: first) != nil)
            #expect(column(of: "]", in: first) == column(of: "]", in: later))
            #expect(column(of: "%", in: first) == column(of: "%", in: later))
        }
    }

    @Test("the rate and the time left wait until the estimate means something; a time left over a day is not shown")
    func estimatesWait() {
        let line = Self.line()
        #expect(line.text(done: 40_000_000, now: 1_001.9) == "Downloading \(Self.modelID)  0%  0.0/16.3 GB")
        #expect(line.text(done: 240_000_000, now: 1_002)
            == "Downloading \(Self.modelID)  1%  0.2/16.3 GB  120 MB/s  2m 13s left")
        // Stalled at 100 KB/s, the rest would take 45 hours.
        #expect(line.text(done: 1_000_000, now: 1_010) == "Downloading \(Self.modelID)  0%  0.0/16.3 GB  100 KB/s")
    }

    @Test("without a width the line is the plain form for logs: the same figures and no bar")
    func plainForm() {
        #expect(Self.line().text(done: Self.done, now: Self.now)
            == "Downloading \(Self.modelID)  43%  7.0/16.3 GB  125 MB/s  1m 14s left")
    }

    @Test("the rate counts only bytes that arrived after the start; rate and time left wait for them")
    func rateLeavesOutBytesAlreadyOnDisk() {
        let resumed = Self.line(startBytes: 7_000_000_000)
        #expect(resumed.bytesPerSecond(done: 7_500_000_000, now: 1_004) == 125_000_000)
        #expect(resumed.bytesPerSecond(done: 7_000_000_000, now: 1_004) == nil)
        #expect(resumed.bytesPerSecond(done: 7_500_000_000, now: 1_000) == nil)
        // A discarded part file can take the count below the start.
        #expect(resumed.bytesPerSecond(done: 6_000_000_000, now: 1_010) == nil)
        #expect(resumed.text(done: 7_000_000_000, now: 1_000) == "Downloading \(Self.modelID)  42%  7.0/16.3 GB")
        #expect(Self.line().text(done: Self.total, now: 1_100) == "Downloading \(Self.modelID)  100%  16.3/16.3 GB  163 MB/s")
    }

    @Test("a terminal redraw is due at most every quarter second")
    func redrawThrottle() {
        var line = Self.line()
        let due = [1_000, 1_000.1, 1_000.24, 1_000.25, 1_000.3].map { line.takeRedraw(now: $0) }
        #expect(due == [true, false, false, true, false])
    }

    @Test("a log line is due first, then when both 10 points and 30 s have passed, and once when it ended")
    func logThrottle() {
        var line = Self.line()
        func bytes(_ percent: Double) -> Int64 { Int64(Double(Self.total) * percent / 100) }
        let samples: [(done: Int64, now: TimeInterval, ended: Bool)] = [
            (0, 1_000, false),
            (bytes(50.5), 1_029, false),  // 50 points in 29 s
            (bytes(50.5), 1_030, false),
            (bytes(59.5), 1_100, false),  // 9 points in 70 s
            (bytes(60.5), 1_101, false),
            (Self.total, 1_102, false),   // 1 s
            (Self.total, 1_102, true),
            (Self.total, 1_103, true),    // 100% already logged
        ]
        let due = samples.map { line.takeLogLine(done: $0.done, now: $0.now, ended: $0.ended) }
        #expect(due == [true, false, true, false, true, false, true, false])
        // Nothing was logged before the end (nothing was transferred): no line for it.
        var untransferred = Self.line()
        let endedFirst = untransferred.takeLogLine(done: Self.total, now: 1_000, ended: true)
        #expect(!endedFirst)
    }

    @Test("sizes and rates use decimal units, as the catalog gives model sizes")
    func units() {
        #expect(TransferProgressLine.bytes(16_300_000_000) == "16.3 GB")
        #expect(TransferProgressLine.bytes(512_000_000) == "512.0 MB")
        #expect(TransferProgressLine.bytes(40_960) == "41 KB")
        #expect(TransferProgressLine.bytes(900) == "900 B")
        #expect(TransferProgressLine.bytes(120_000_000, of: 500_000_000) == "120.0/500.0 MB")
        #expect(TransferProgressLine.rate(125_000_000) == "125 MB/s")
        #expect(TransferProgressLine.rate(2_400_000_000) == "2.4 GB/s")
        #expect(TransferProgressLine.rate(512_000) == "512 KB/s")
        // A unit stops below its rounding into the next, and the rate has a widest form.
        #expect(TransferProgressLine.rate(999_400) == "999 KB/s")
        #expect(TransferProgressLine.rate(999_600) == "1 MB/s")
        #expect(TransferProgressLine.rate(999_600_000) == "1.0 GB/s")
        #expect(TransferProgressLine.rate(1e12) == "99.9 GB/s")
        #expect(TransferProgressLine.duration(45) == "45s")
        #expect(TransferProgressLine.duration(74.24) == "1m 14s")
        #expect(TransferProgressLine.duration(7_500) == "2h 5m")
    }

    // MARK: - The tracker

    @Test("the tracker sums bytes on disk across files, with resumed prefixes, restarts and completions")
    func trackerSumsFiles() {
        let progress = ManifestDownloadProgress()
        progress.register(label: "a", expectedBytes: 100, initialBytes: 40)
        progress.register(label: "b", expectedBytes: 300)
        #expect(progress.downloadedBytes == 40)
        progress.update(label: "a", downloadedBytes: 70)
        progress.update(label: "b", downloadedBytes: 120)
        #expect(progress.downloadedBytes == 190)
        // A discarded part file restarts its transfer.
        progress.update(label: "a", downloadedBytes: 0)
        #expect(progress.downloadedBytes == 120)
        progress.complete(label: "a")
        progress.update(label: "unregistered", downloadedBytes: 999)
        #expect(progress.downloadedBytes == 220)
    }

    // MARK: - The renderer

    /// A checkpoint's metadata and five weight shards, 16.3 GB in all.
    private static let checkpoint: [(label: String, bytes: Int64)] =
        [(label: "config.json", bytes: 8_700), (label: "tokenizer.json", bytes: 17_000_000)]
        + (1...5).map { (label: String(format: "model-%05d-of-00005.safetensors", $0), bytes: Int64(3_256_598_260)) }

    private static let displayName = "Qwen 3.8 27B"

    private static func renderer(isTerminal: Bool, columns: Int = 100, startBytes: Int64 = 0,
                                 clock: ManualClock, into output: CapturedOutput) -> DownloadProgressRenderer {
        DownloadProgressRenderer(
            modelID: modelID, displayName: displayName, totalBytes: total, startBytes: startBytes,
            terminal: DownloadProgressTerminal(isTerminal: isTerminal, columns: { columns }, clock: { clock.now },
                                               output: { output.append($0) }))
    }

    /// Fetches `checkpoint` four files at a time at 125 MB/s in all, after
    /// `stalled` seconds at 100 KB/s, through the downloader's byte tracker,
    /// which the render loop samples every 0.1 s here, until `share` of the
    /// bytes are on disk.
    @discardableResult
    private static func download(_ renderer: DownloadProgressRenderer, clock: ManualClock,
                                 until share: Double = 1, stalled: TimeInterval = 0) -> ManifestDownloadProgress {
        let progress = ManifestDownloadProgress()
        for file in checkpoint { progress.register(label: file.label, expectedBytes: file.bytes) }
        var queued = checkpoint[...]
        var inFlight: [(label: String, bytes: Int64, done: Int64)] = []
        var elapsed: TimeInterval = 0
        while Double(progress.downloadedBytes) < Double(total) * share {
            while inFlight.count < 4, let next = queued.popFirst() { inFlight.append((next.label, next.bytes, 0)) }
            guard !inFlight.isEmpty else { break }
            clock.advance(0.1)
            elapsed += 0.1
            let each = (elapsed < stalled ? 10_000 : 12_500_000) / Int64(inFlight.count)
            for index in inFlight.indices {
                inFlight[index].done = min(inFlight[index].bytes, inFlight[index].done + each)
                progress.update(label: inFlight[index].label, downloadedBytes: inFlight[index].done)
            }
            for file in inFlight where file.done == file.bytes { progress.complete(label: file.label) }
            inFlight.removeAll { $0.done == $0.bytes }
            renderer.update(done: progress.downloadedBytes)
        }
        return progress
    }

    /// The rows a terminal was given, one per redraw.
    private static func redraws(_ output: String) -> [String] {
        output.replacingOccurrences(of: "\u{1B}[K", with: "").components(separatedBy: "\r").filter { !$0.isEmpty }
    }

    /// The cells between the brackets of a redraw's bar, if it has one.
    private static func barWidth(_ frame: String) -> Int? {
        guard let open = frame.firstIndex(of: "["), let close = frame.firstIndex(of: "]") else { return nil }
        return frame.distance(from: open, to: close) - 1
    }

    @Test("on a terminal every file's progress is one line, redrawn at most four times a second")
    func terminalShowsOneLine() {
        let clock = ManualClock()
        let output = CapturedOutput()
        let renderer = Self.renderer(isTerminal: true, clock: clock, into: output)
        let progress = Self.download(renderer, clock: clock, until: 0.5)
        let elapsed = clock.now - 1_000
        let redraws = Self.redraws(output.value)
        #expect(!output.value.contains("\n"))
        #expect(redraws.count <= Int(elapsed * 4) + 1)
        #expect(redraws.allSatisfy { $0.count <= 99 })

        // The shards in flight are each further along than the download as a
        // whole; the line shows the whole download.
        clock.advance(0.3)
        let done = progress.downloadedBytes
        renderer.update(done: done)
        var terminal = VirtualTerminal(columns: 100)
        terminal.feed(output.value)
        #expect(terminal.scrollback.isEmpty)
        #expect(terminal.visibleLines.count == 1)
        let row = terminal.visibleLines.first ?? ""
        #expect(row.hasPrefix("  Downloading \(Self.modelID)  ["))
        #expect(row.contains(" \(Int(Double(done) / Double(Self.total) * 100))%  "))
        #expect(row.contains(" \(TransferProgressLine.bytes(done, of: Self.total))  "))
        #expect(!row.contains("safetensors"))
    }

    @Test("every redraw of a download keeps the bar's width and each figure's column, from the first frame on",
          arguments: [60, 80, 100, 120])
    func columnsStayPut(columns: Int) throws {
        let clock = ManualClock()
        let output = CapturedOutput()
        let renderer = Self.renderer(isTerminal: true, columns: columns, clock: clock, into: output)
        // A slow start, so every figure changes its length on the way.
        Self.download(renderer, clock: clock, stalled: 5)
        let frames = Self.redraws(output.value)
        try #require(frames.count > 100)
        // The first frame comes before there is a rate or a time left.
        #expect(!frames[0].contains("B/s") && !frames[0].contains("left"))
        if columns >= 120 {
            // While the start is slow the rate shows, but not a time left of more than a day.
            #expect(frames.contains { $0.contains(" KB/s") && !$0.contains(" left") })
        }
        /// The columns where `pattern` ends, in the frames that show it.
        func ends(_ pattern: String) -> Set<Int> {
            Set(frames.compactMap { frame in
                frame.range(of: pattern, options: .regularExpression).map { frame.distance(from: frame.startIndex, to: $0.upperBound) }
            })
        }
        let barWidths = Set(frames.compactMap(Self.barWidth))
        #expect(barWidths.count == 1, "bar widths: \(barWidths)")
        #expect(Set(frames.map { $0.prefix { $0 != "[" } }).count == 1)
        #expect(ends(#"\d+%"#).count == 1)
        for figure in [#"\d+\.\d/\d+\.\d GB"#, #"\d+(\.\d)? [KMG]?B/s"#, " left"] {
            #expect(ends(figure).count <= 1, "\(figure) ends at \(ends(figure))")
        }
        if columns >= 80 { #expect(ends(" left").count == 1) }
    }

    @Test("a resized window gets a new layout, which then stays put until the width changes again")
    func resizedWindow() {
        let clock = ManualClock()
        let output = CapturedOutput()
        let window = WindowWidth(120)
        let renderer = DownloadProgressRenderer(
            modelID: Self.modelID, displayName: Self.displayName, totalBytes: Self.total, startBytes: 0,
            terminal: DownloadProgressTerminal(isTerminal: true, columns: { window.columns }, clock: { clock.now },
                                               output: { output.append($0) }))
        var done: Int64 = 0
        /// `count` redraws at 125 MB/s.
        func redraw(_ count: Int) {
            for _ in 0..<count {
                clock.advance(TransferProgressLine.redrawInterval)
                done += 31_250_000
                renderer.update(done: done)
            }
        }
        redraw(40)
        let wide = Self.redraws(output.value)
        window.resize(to: 80)
        redraw(40)
        let narrow = Array(Self.redraws(output.value).dropFirst(wide.count))
        #expect(wide.count == 40 && narrow.count == 40)
        // 26 cells at 120 columns, 11 at 80.
        #expect(Set(wide.compactMap(Self.barWidth)) == [26])
        #expect(Set(narrow.compactMap(Self.barWidth)) == [11])
        #expect(narrow.allSatisfy { $0.count < 80 })
    }

    @Test("the summary replaces the line when the download is verified, and the next output goes below it")
    func terminalSummary() {
        let clock = ManualClock()
        let output = CapturedOutput()
        let renderer = Self.renderer(isTerminal: true, clock: clock, into: output)
        Self.download(renderer, clock: clock)
        renderer.verifying()
        var terminal = VirtualTerminal(columns: 100)
        terminal.feed(output.value)
        #expect(terminal.visibleLines == ["  Verifying \(Self.modelID) (16.3 GB)\u{2026}"])

        clock.advance(5)
        renderer.finish()
        output.append("next\n")
        terminal = VirtualTerminal(columns: 100)
        terminal.feed(output.value)
        let elapsed = TransferProgressLine.duration(clock.now - 1_000)
        #expect(terminal.transcript == ["  \u{2713} Downloaded \(Self.displayName) (16.3 GB in \(elapsed))", "next"])
        #expect(output.value.filter { $0 == "\n" }.count == 2)
    }

    @Test("a narrow terminal cuts the line to fit, so a redraw never wraps", arguments: [20, 40, 60, 80])
    func narrowTerminalsNeverWrap(columns: Int) {
        let clock = ManualClock()
        let output = CapturedOutput()
        let renderer = Self.renderer(isTerminal: true, columns: columns, clock: clock, into: output)
        Self.download(renderer, clock: clock)
        renderer.verifying()
        #expect(Self.redraws(output.value).allSatisfy { $0.count < columns })
        var terminal = VirtualTerminal(columns: columns)
        terminal.feed(output.value)
        #expect(terminal.scrollback.isEmpty)
        #expect(terminal.visibleLines.count == 1)
    }

    @Test("without a terminal a few plain lines are printed: the start, every 10 points and 30 s, the end, the check and the summary")
    func plainOutputIsRare() throws {
        let clock = ManualClock()
        let output = CapturedOutput()
        let renderer = Self.renderer(isTerminal: false, clock: clock, into: output)
        Self.download(renderer, clock: clock)
        let downloading = clock.now - 1_000
        renderer.verifying()
        renderer.finish()

        #expect(!output.value.contains("\r") && !output.value.contains("\u{1B}"))
        let lines = output.lines
        let progress = lines.filter { $0.hasPrefix("  Downloading \(Self.modelID)  ") }
        let percents = try progress.map { line in
            try #require(line.split(separator: " ").first { $0.hasSuffix("%") }.flatMap { Int($0.dropLast()) })
        }
        #expect(percents.first == 0 && percents.last == 100)
        let throttled = percents.dropLast()
        #expect(zip(throttled, throttled.dropFirst()).allSatisfy { $1 - $0 >= TransferProgressLine.logPercentStep })
        // The first line, one per 30 s at most, and the line when the last byte arrived.
        #expect(progress.count <= Int(downloading / TransferProgressLine.logInterval) + 2)
        #expect(Array(lines.dropFirst(progress.count)) == [
            "  Verifying \(Self.modelID) (16.3 GB)\u{2026}",
            "  \u{2713} Downloaded \(Self.displayName) (16.3 GB in \(TransferProgressLine.duration(downloading)))",
        ])
    }

    @Test("a download that stops says where, on a terminal and off it", arguments: [true, false])
    func failureLine(isTerminal: Bool) {
        let clock = ManualClock()
        let output = CapturedOutput()
        let renderer = Self.renderer(isTerminal: isTerminal, clock: clock, into: output)
        let progress = Self.download(renderer, clock: clock, until: 0.43)
        renderer.fail(done: progress.downloadedBytes)
        let stopped = "  Download of \(Self.modelID) stopped at 43% (7.0/16.3 GB)"
        if isTerminal {
            var terminal = VirtualTerminal(columns: 100)
            terminal.feed(output.value)
            #expect(terminal.transcript == [stopped])
        } else {
            #expect(output.lines.last == stopped)
        }
    }

    @Test("the summary says how much was already on disk when the download resumed")
    func resumedSummary() {
        let clock = ManualClock()
        let output = CapturedOutput()
        let renderer = Self.renderer(isTerminal: false, startBytes: 7_000_000_000, clock: clock, into: output)
        clock.advance(60)
        renderer.finish()
        #expect(output.lines == ["  \u{2713} Downloaded \(Self.displayName) (16.3 GB in 1m 0s; 7.0 GB of it was already on disk)"])
    }
}

// MARK: - Through the downloader

/// A CDN for the downloader: path to body, each sent after its delay; others are 404.
private final class ProgressCDNProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var bodies: [String: Data] = [:]
    nonisolated(unsafe) private static var delays: [String: TimeInterval] = [:]

    static func serve(_ files: [String: Data], delays: [String: TimeInterval]) {
        lock.withLock {
            bodies.merge(files) { $1 }
            self.delays.merge(delays) { $1 }
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let (body, delay) = Self.lock.withLock { (Self.bodies[url.path], Self.delays[url.path] ?? 0) }
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [self] in
            guard let body else {
                let missing = HTTPURLResponse(url: url, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: nil)!
                client?.urlProtocol(self, didReceive: missing, cacheStoragePolicy: .notAllowed)
                client?.urlProtocolDidFinishLoading(self)
                return
            }
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Length": "\(body.count)"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}

/// Every (bytes so far, total bytes) a caller that owns the screen is given.
private final class ByteSamples: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [(done: Int64, total: Int64)] = []

    func append(_ done: Int64, _ total: Int64) { lock.withLock { samples.append((done, total)) } }

    var last: (done: Int64, total: Int64)? { lock.withLock { samples.last } }
}

@Suite("Model download progress through the downloader", .serialized)
struct ModelDownloadProgressDownloaderTests {
    private static let cdn = "https://cdn.progress-line.test"

    /// A model on the fake CDN: its catalog entry, where its files live and the files.
    private struct Published {
        let model: CatalogModel
        let prefix: String
        let files: [(path: String, bytes: Data)]
    }

    /// A three-file model on the fake CDN, 300,022 bytes. The weights arrive
    /// half a second after they are asked for, so the render loop runs first.
    /// `aggregateSHA256` replaces the digest of the files in the manifest.
    private static func publishedModel(missing: String? = nil, aggregateSHA256: String? = nil) throws -> Published {
        let id = UUID().uuidString
        let prefix = "v2/progress-line/\(id)"
        let files: [(path: String, bytes: Data)] = [
            ("config.json", Data(#"{"model_type": "test"}"#.utf8)),
            ("model-00001-of-00002.safetensors", Data((0..<200_000).map { UInt8($0 & 0xFF) })),
            ("model-00002-of-00002.safetensors", Data((0..<100_000).map { UInt8(($0 &* 7) & 0xFF) })),
        ]
        func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 { digest.map { String(format: "%02x", $0) }.joined() }
        var aggregate = SHA256()
        for file in files.sorted(by: { $0.path < $1.path }) { aggregate.update(data: Data(SHA256.hash(data: file.bytes))) }
        let manifest = ModelManifest(
            schemaVersion: 1, modelID: "test-org/progress-line-\(id)", version: "v1", r2Prefix: prefix,
            aggregateSHA256: aggregateSHA256 ?? hex(aggregate.finalize()),
            totalSizeBytes: files.reduce(0) { $0 + Int64($1.bytes.count) },
            fileCount: files.count,
            files: files.map {
                ManifestFile(path: $0.path, sizeBytes: Int64($0.bytes.count), sha256: hex(SHA256.hash(data: $0.bytes)),
                             role: $0.path.hasSuffix(".safetensors") ? "weight" : "config")
            },
            createdAt: Date(timeIntervalSince1970: 0))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var bodies = ["/\(prefix)/manifest.json": try encoder.encode(manifest)]
        for file in files where file.path != missing { bodies["/\(prefix)/\(file.path)"] = file.bytes }
        ProgressCDNProtocol.serve(bodies, delays: Dictionary(uniqueKeysWithValues: files.filter { $0.path.hasSuffix(".safetensors") }
            .map { ("/\(prefix)/\($0.path)", 0.5) }))
        let model = CatalogModel(id: manifest.modelID, s3Name: "unused", displayName: "Progress line", sizeGb: 0.0003,
                                 r2Prefix: prefix, aggregateSHA256: manifest.aggregateSHA256)
        return Published(model: model, prefix: prefix, files: files)
    }

    private static func downloader(isTerminal: Bool, into output: CapturedOutput) -> ModelDownloader {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProgressCDNProtocol.self]
        var downloader = ModelDownloader(r2CDNURL: cdn, urlSession: URLSession(configuration: configuration),
                                         retryBackoff: .milliseconds(1))
        // A clock that does not move: what is printed depends on the bytes only.
        downloader.progressTerminal = DownloadProgressTerminal(
            isTerminal: isTerminal, columns: { 120 }, clock: { 1_000 }, output: { output.append($0) })
        return downloader
    }

    @Test("off a terminal a download prints its start, its end, the check and its one completion line, and nothing per file")
    func plainDownload() async throws {
        let model = try Self.publishedModel().model
        defer { try? FileManager.default.removeItem(at: ModelDownloader.cacheModelDirectory(for: model.id)) }
        let output = CapturedOutput()
        try await Self.downloader(isTerminal: false, into: output).download(model: model)
        #expect(output.lines == [
            "  Downloading \(model.id)  0%  0/300 KB",
            "  Downloading \(model.id)  100%  300/300 KB",
            "  Verifying \(model.id) (300 KB)\u{2026}",
            "  \u{2713} Downloaded Progress line (300 KB in 0s)",
        ])
    }

    @Test("on a terminal a download leaves only its completion line on screen")
    func terminalDownload() async throws {
        let model = try Self.publishedModel().model
        defer { try? FileManager.default.removeItem(at: ModelDownloader.cacheModelDirectory(for: model.id)) }
        let output = CapturedOutput()
        try await Self.downloader(isTerminal: true, into: output).download(model: model)
        #expect(output.value.filter { $0 == "\n" }.count == 1 && output.value.hasSuffix("\n"))
        var terminal = VirtualTerminal(columns: 120)
        terminal.feed(output.value)
        #expect(terminal.transcript == ["  \u{2713} Downloaded Progress line (300 KB in 0s)"])
    }

    @Test("a model whose files are already there and verified gets one line that says so")
    func alreadyDownloaded() async throws {
        let model = try Self.publishedModel().model
        defer { try? FileManager.default.removeItem(at: ModelDownloader.cacheModelDirectory(for: model.id)) }
        try await Self.downloader(isTerminal: false, into: CapturedOutput()).download(model: model)
        let output = CapturedOutput()
        try await Self.downloader(isTerminal: false, into: output).download(model: model)
        #expect(output.lines == ["  \u{2713} Progress line is already downloaded (300 KB)"])
    }

    @Test("files an earlier run left staged are checked and published with one completion line")
    func finishedFromStaging() async throws {
        let published = try Self.publishedModel()
        let model = published.model
        defer { try? FileManager.default.removeItem(at: ModelDownloader.cacheModelDirectory(for: model.id)) }
        let staging = ModelDownloader.cacheSnapshotDirectory(for: model.id).deletingLastPathComponent()
            .appendingPathComponent(ModelDownloader.localStagingDirName(r2Prefix: published.prefix), isDirectory: true)
        for file in published.files {
            let destination = staging.appendingPathComponent(file.path)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try file.bytes.write(to: destination)
        }
        let output = CapturedOutput()
        try await Self.downloader(isTerminal: false, into: output).download(model: model)
        #expect(output.lines == [
            "  Verifying \(model.id) (300 KB)\u{2026}",
            "  \u{2713} Downloaded Progress line (300 KB in 0s; 300 KB of it was already on disk)",
        ])
    }

    @Test("a caller that shows the progress itself gets every count, the complete one last, and no line is drawn")
    func callerOwnsTheScreen() async throws {
        let model = try Self.publishedModel().model
        defer { try? FileManager.default.removeItem(at: ModelDownloader.cacheModelDirectory(for: model.id)) }
        let output = CapturedOutput()
        let samples = ByteSamples()
        var downloader = Self.downloader(isTerminal: true, into: output)
        downloader.byteProgress = { samples.append($0, $1) }
        try await downloader.download(model: model)
        #expect(output.value.isEmpty)
        let last = try #require(samples.last)
        #expect(last.done == 300_022 && last.total == 300_022)
    }

    @Test("a download that fails ends its line with where it stopped, then throws")
    func failedDownload() async throws {
        let model = try Self.publishedModel(missing: "model-00002-of-00002.safetensors").model
        defer { try? FileManager.default.removeItem(at: ModelDownloader.cacheModelDirectory(for: model.id)) }
        let output = CapturedOutput()
        await #expect(throws: ModelCatalogError.self) {
            try await Self.downloader(isTerminal: false, into: output).download(model: model)
        }
        #expect(output.lines.first == "  Downloading \(model.id)  0%  0/300 KB")
        #expect(output.lines.last?.hasPrefix("  Download of \(model.id) stopped at ") == true)
        #expect(output.lines.count == 2)
    }

    @Test("a download whose files fail the check against the manifest replaces its line with the failed check and why, then throws")
    func failedCheck() async throws {
        let model = try Self.publishedModel(aggregateSHA256: String(repeating: "0", count: 64)).model
        defer { try? FileManager.default.removeItem(at: ModelDownloader.cacheModelDirectory(for: model.id)) }
        let output = CapturedOutput()
        await #expect(throws: ModelCatalogError.self) {
            try await Self.downloader(isTerminal: true, into: output).download(model: model)
        }
        #expect(output.value.contains("Verifying \(model.id) (300 KB)\u{2026}"))
        var terminal = VirtualTerminal(columns: 120)
        terminal.feed(output.value)
        // The line is longer than the window and wraps onto a second row.
        #expect(terminal.transcript.joined() == "  Verification of \(model.id) failed: aggregate hash mismatch for \(model.id)")
    }
}
