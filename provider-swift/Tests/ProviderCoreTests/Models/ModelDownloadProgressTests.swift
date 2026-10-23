import Foundation
import Testing

@testable import ProviderCore

/// Collects everything a `ProgressRenderer` writes, one chunk per write.
private final class CapturedOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var writes: [String] = []

    func append(_ chunk: String) {
        lock.lock()
        defer { lock.unlock() }
        writes.append(chunk)
    }

    /// Each write in order; the renderer emits one per frame.
    var chunks: [String] {
        lock.lock()
        defer { lock.unlock() }
        return writes
    }

    var value: String { chunks.joined() }
}

/// A VT100 screen model covering what the renderer emits: printable text with
/// deferred auto-wrap, LF (with the tty's carriage return), CR, `ESC[nA` and
/// `ESC[J`. Cursor-up is clamped at the top row exactly as real terminals do,
/// and rows that scroll off the top accumulate in `scrollback`.
private struct VirtualTerminal {
    let columns: Int
    let rows: Int
    private(set) var screen: [[Character]]
    private(set) var scrollback: [String] = []
    private var row = 0
    private var column = 0
    private var wrapPending = false

    init(columns: Int, rows: Int) {
        self.columns = columns
        self.rows = rows
        screen = Array(repeating: Array(repeating: " ", count: columns), count: rows)
    }

    /// Visible rows with trailing blanks trimmed.
    var visibleLines: [String] { screen.map(Self.trimmed) }

    /// Every non-blank row ever displayed, oldest first.
    var transcript: [String] { (scrollback + visibleLines).filter { !$0.isEmpty } }

    mutating func feed(_ text: String) {
        var scalars = Array(text.unicodeScalars)[...]
        while let scalar = scalars.popFirst() {
            switch scalar {
            case "\u{1B}":
                guard scalars.popFirst() == "[" else {
                    Issue.record("escape without a control sequence introducer")
                    return
                }
                var digits = ""
                while let next = scalars.first, ("0"..."9").contains(next) {
                    digits.unicodeScalars.append(next)
                    scalars.removeFirst()
                }
                switch scalars.popFirst() {
                case "A"?:
                    row = max(0, row - (Int(digits) ?? 1))
                    wrapPending = false
                case "J"?:
                    eraseToEndOfScreen()
                case let other:
                    Issue.record("unexpected control sequence final byte \(String(describing: other))")
                    return
                }
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

    private mutating func eraseToEndOfScreen() {
        for c in column..<columns { screen[row][c] = " " }
        for r in (row + 1)..<rows { screen[r] = Array(repeating: " ", count: columns) }
    }

    private static func trimmed(_ cells: [Character]) -> String {
        var line = String(cells)
        while line.last == " " { line.removeLast() }
        return line
    }
}

@Suite("Model download progress rendering")
struct ModelDownloadProgressTests {

    /// A checkpoint layout like the one that scrolled endlessly: metadata, 88
    /// weight shards and tokenizer files, far more files than terminal rows.
    private static let manyFileManifest: [(label: String, bytes: Int64)] = {
        var files: [(label: String, bytes: Int64)] = [
            ("chat_template.jinja", 12_900), ("config.json", 8_700_000),
            ("generation_config.json", 209), ("LICENSE.txt", 2_660),
        ]
        let shardBytes: [Int64] = [1_610_000_000, 109_700_000, 35_650_000]
        for index in 1...88 {
            files.append((String(format: "model-%05d-of-00088.safetensors", index), shardBytes[index % 3]))
        }
        return files + [("model.safetensors.index.json", 160_000), ("tokenizer.json", 17_000_000)]
    }()

    private static func tracker(_ files: [(label: String, bytes: Int64)]) -> ManifestDownloadProgress {
        let progress = ManifestDownloadProgress()
        for file in files { progress.register(label: file.label, expectedBytes: file.bytes) }
        return progress
    }

    private static func renderer(
        isTTY: Bool = true, columns: Int, rows: Int, into output: CapturedOutput
    ) -> ProgressRenderer {
        ProgressRenderer(
            isTTY: isTTY,
            terminalSize: { .init(columns: columns, rows: rows) },
            output: { output.append($0) })
    }

    /// Starts the first four shards of `manyFileManifest` and renders `frames`
    /// frames of them advancing.
    private static func renderShardsInFlight(
        columns: Int, rows: Int, frames: Int = 40
    ) -> (output: CapturedOutput, inFlight: [String]) {
        let progress = tracker(manyFileManifest)
        let output = CapturedOutput()
        let renderer = renderer(columns: columns, rows: rows, into: output)
        let inFlight = manyFileManifest[4..<8].map(\.label)
        for label in inFlight { progress.start(label: label) }
        for frame in 1...frames {
            for label in inFlight { progress.update(label: label, downloadedBytes: Int64(frame) * 500_000) }
            renderer.render(progress.allProgress)
        }
        return (output, inFlight)
    }

    @Test("more files than terminal rows redraw in place instead of scrolling", arguments: [24, 8, 3, 2])
    func manyFilesRedrawInPlace(rows: Int) {
        let (output, inFlight) = Self.renderShardsInFlight(columns: 120, rows: rows)

        var terminal = VirtualTerminal(columns: 120, rows: rows)
        terminal.feed(output.value)
        #expect(terminal.scrollback.isEmpty)
        let live = terminal.visibleLines.filter { !$0.isEmpty }
        // Four in-flight bars plus the total row, as many as fit above the cursor.
        #expect(live.count == min(5, rows - 1))
        #expect(live.last?.hasPrefix("    total 0/\(Self.manyFileManifest.count) files") == true)
        #expect(zip(live.dropLast(), inFlight).allSatisfy { $0.hasPrefix("    \($1)  [") })
    }

    @Test("a one-row terminal gets no live rows rather than scrolling")
    func oneRowTerminal() {
        let (output, _) = Self.renderShardsInFlight(columns: 120, rows: 1)
        #expect(output.value.isEmpty)
    }

    @Test("keys echoed on the cursor row do not shift the redraw")
    func echoedKeysDoNotShiftRows() {
        let (output, inFlight) = Self.renderShardsInFlight(columns: 120, rows: 24)
        var terminal = VirtualTerminal(columns: 120, rows: 24)
        // A user typing during the download echoes keys on the cursor row
        // between frames; the renderer writes each frame in one call.
        for frame in output.chunks {
            terminal.feed(frame)
            terminal.feed("abc")
        }
        // The last non-blank row holds the keys typed after the final frame.
        let live = terminal.visibleLines.filter { !$0.isEmpty }.dropLast()
        #expect(terminal.scrollback.isEmpty)
        #expect(live.count == inFlight.count + 1)
        #expect(zip(live, inFlight).allSatisfy { $0.hasPrefix("    \($1)  [") })
    }

    @Test(
        "rows share one column layout and keep a bar down to an 80-column terminal",
        arguments: [(80, false), (100, true), (120, true), (230, true)])
    func sharedColumns(columns: Int, showsRate: Bool) throws {
        let (output, inFlight) = Self.renderShardsInFlight(columns: columns, rows: 24)
        var terminal = VirtualTerminal(columns: columns, rows: 24)
        terminal.feed(output.value)
        let live = terminal.visibleLines.filter { !$0.isEmpty }

        #expect(live.count == inFlight.count + 1)
        func markColumns(_ mark: Character) -> Set<Int> {
            Set(live.compactMap { row in row.firstIndex(of: mark).map { row.distance(from: row.startIndex, to: $0) } })
        }
        let barStarts = markColumns("[")
        let barEnds = markColumns("]")
        #expect(barStarts.count == 1 && barEnds.count == 1)
        let barWidth = try #require(barEnds.first) - (try #require(barStarts.first)) - 1
        #expect(barWidth >= 10 && barWidth <= 40)
        #expect(live.allSatisfy { $0.contains("B/s") } == showsRate)
        // Shortened shard labels keep the shard number.
        #expect(zip(live, inFlight).allSatisfy { row, label in
            row.hasPrefix("    " + (label as NSString).deletingPathExtension)
        })
    }

    @Test("each finished file is logged once, in aligned columns, and finish clears the live rows")
    func completionsLoggedOnce() {
        let files = Self.manyFileManifest
        let progress = Self.tracker(files)
        let output = CapturedOutput()
        let renderer = Self.renderer(columns: 120, rows: 24, into: output)

        var queue = files.map(\.label)[...]
        var inFlight: [String] = []
        while !queue.isEmpty || !inFlight.isEmpty {
            while inFlight.count < 4, let label = queue.popFirst() {
                progress.start(label: label)
                inFlight.append(label)
            }
            renderer.render(progress.allProgress)
            progress.complete(label: inFlight.removeFirst())
            renderer.render(progress.allProgress)
        }
        renderer.finish(progress.allProgress)

        var terminal = VirtualTerminal(columns: 120, rows: 24)
        terminal.feed(output.value)
        // Only the completion log remains: one line per file, no stale live rows.
        #expect(terminal.transcript.count == files.count)
        for file in files {
            #expect(terminal.transcript.filter { $0.hasPrefix("  \u{2713} \(file.label) ") }.count == 1)
        }
        #expect(Set(terminal.transcript.map(\.count)).count == 1)
    }

    @Test("finish logs files that completed after the last frame")
    func finishLogsLateCompletions() {
        let progress = Self.tracker([("config.json", 100), ("model.safetensors", 1_000)])
        let output = CapturedOutput()
        let renderer = Self.renderer(columns: 100, rows: 24, into: output)
        progress.start(label: "config.json")
        progress.start(label: "model.safetensors")
        renderer.render(progress.allProgress)
        progress.complete(label: "config.json")
        progress.complete(label: "model.safetensors")
        renderer.finish(progress.allProgress)

        var terminal = VirtualTerminal(columns: 100, rows: 24)
        terminal.feed(output.value)
        #expect(terminal.transcript.count == 2)
        #expect(terminal.transcript.first?.hasPrefix("  \u{2713} config.json ") == true)
        #expect(terminal.transcript.first?.contains(" 100 B ") == true)
        #expect(terminal.transcript.last?.hasPrefix("  \u{2713} model.safetensors ") == true)
        #expect(terminal.transcript.last?.contains(" 1000 B ") == true)
    }

    @Test("a single-file download shows its bar without a total row")
    func singleFileHasNoTotalRow() {
        let progress = Self.tracker([("model.safetensors", 4_000_000_000)])
        let output = CapturedOutput()
        let renderer = Self.renderer(columns: 120, rows: 24, into: output)
        progress.start(label: "model.safetensors")
        progress.update(label: "model.safetensors", downloadedBytes: 1_000_000_000)
        renderer.render(progress.allProgress)

        var terminal = VirtualTerminal(columns: 120, rows: 24)
        terminal.feed(output.value)
        let live = terminal.visibleLines.filter { !$0.isEmpty }
        #expect(live.count == 1)
        #expect(live.first?.hasPrefix("    model.safetensors  [") == true)
        #expect(live.first?.contains(" 25% ") == true)
    }

    @Test("live rows fit the terminal width, so a narrow terminal does not scroll", arguments: [20, 40, 60, 80, 100, 200])
    func rowsFitWidth(columns: Int) {
        let labels = [
            "model-00001-of-00088.safetensors",
            "transformer/diffusion_pytorch_model-00001-of-00012.safetensors",
            "LICENSE",
        ]
        let progress = Self.tracker(labels.map { ($0, 2_900_000_000) })
        let output = CapturedOutput()
        let renderer = Self.renderer(columns: columns, rows: 24, into: output)
        for label in labels { progress.start(label: label) }

        for frame in 1...20 {
            for label in labels { progress.update(label: label, downloadedBytes: Int64(frame) * 100_000_000) }
            renderer.render(progress.allProgress)
        }

        let drawnRows = output.value
            .replacingOccurrences(of: "\u{1B}\\[\\d*[AJ]", with: "", options: .regularExpression)
            .split(whereSeparator: \.isNewline)
        // The last column stays free so a narrowing resize does not rewrap rows.
        #expect(drawnRows.allSatisfy { $0.count < columns })
        var terminal = VirtualTerminal(columns: columns, rows: 24)
        terminal.feed(output.value)
        #expect(terminal.scrollback.isEmpty)
        #expect(terminal.visibleLines.filter { !$0.isEmpty }.count == labels.count + 1)
    }

    @Test("without a terminal only completion lines are printed, once each")
    func plainOutput() {
        let progress = Self.tracker([("a.json", 10), ("b.safetensors", 1_000), ("c.json", 20)])
        let output = CapturedOutput()
        let renderer = Self.renderer(isTTY: false, columns: 80, rows: 24, into: output)
        for label in ["a.json", "b.safetensors", "c.json"] { progress.start(label: label) }

        renderer.render(progress.allProgress)
        progress.complete(label: "c.json")
        renderer.render(progress.allProgress)
        renderer.render(progress.allProgress)
        progress.complete(label: "a.json")
        progress.complete(label: "b.safetensors")
        renderer.finish(progress.allProgress)

        let lines = output.value.split(separator: "\n").map(String.init)
        #expect(!output.value.contains("\u{1B}"))
        #expect(lines.count == 3)
        #expect(lines.map { $0.split(separator: " ")[1] } == ["c.json", "a.json", "b.safetensors"])
    }

    @Test("a queued file is timed from when its transfer starts, not from registration")
    func queuedFileClockStartsAtTransfer() throws {
        let progress = ManifestDownloadProgress()
        progress.register(label: "shard", expectedBytes: 1_000, initialBytes: 250)
        #expect(try #require(progress.allProgress.first).started == false)

        let beforeStart = Date()
        progress.start(label: "shard")

        let shard = try #require(progress.allProgress.first)
        #expect(shard.started)
        #expect(shard.startTime >= beforeStart)
        #expect(shard.baselineBytes == 250)
    }

    @Test("a transfer restarted from a discarded part file is timed afresh")
    func restartedTransferIsRetimed() throws {
        let progress = ManifestDownloadProgress()
        progress.register(label: "shard", expectedBytes: 1_000, initialBytes: 400)
        progress.start(label: "shard")
        progress.update(label: "shard", downloadedBytes: 700)

        let beforeRestart = Date()
        progress.update(label: "shard", downloadedBytes: 0)
        progress.update(label: "shard", downloadedBytes: 100)

        let shard = try #require(progress.allProgress.first)
        #expect(shard.downloadedBytes == 100)
        #expect(shard.baselineBytes == 0)
        #expect(shard.startTime >= beforeRestart)
    }

    @Test("a fallback before the first byte arrives restarts the clock")
    func fallbackBeforeFirstByteIsRetimed() throws {
        let progress = ManifestDownloadProgress()
        progress.register(label: "shard", expectedBytes: 1_000)
        progress.start(label: "shard")

        let beforeFallback = Date()
        progress.update(label: "shard", downloadedBytes: 0)

        #expect(try #require(progress.allProgress.first).startTime >= beforeFallback)
    }

    @Test("the total row sums every file and times the transfer from the first start")
    func aggregateTotals() {
        let firstStart = Date(timeIntervalSinceNow: -30)
        var finished = FileProgress(label: "a", expectedBytes: 100)
        finished.downloadedBytes = 100
        finished.started = true
        finished.completed = true
        finished.startTime = firstStart
        var resumed = FileProgress(label: "b", expectedBytes: 300)
        resumed.downloadedBytes = 120
        resumed.baselineBytes = 20
        resumed.started = true
        resumed.startTime = firstStart.addingTimeInterval(5)
        var queued = FileProgress(label: "c", expectedBytes: 600)
        queued.downloadedBytes = 50
        queued.baselineBytes = 50

        let total = ProgressRenderer.aggregate([finished, resumed, queued])

        #expect(total.label == "total 1/3 files")
        #expect(total.expectedBytes == 1_000)
        #expect(total.downloadedBytes == 270)
        #expect(total.baselineBytes == 70)
        #expect(total.startTime == firstStart)
        #expect(!total.completed)
    }

    @Test("long labels drop their extension first, then keep their tail")
    func labelShortening() {
        let nested = "transformer/diffusion_pytorch_model-00001-of-00012.safetensors"
        #expect(ProgressRenderer.shortenedLabel("config.json", width: 45) == "config.json")
        #expect(ProgressRenderer.shortenedLabel("model-00001-of-00088.safetensors", width: 20) == "model-00001-of-00088")
        #expect(
            ProgressRenderer.shortenedLabel(nested, width: 20)
                == "\u{2026}" + "transformer/diffusion_pytorch_model-00001-of-00012".suffix(19))
        #expect(ProgressRenderer.shortenedLabel(nested, width: 45).count == 45)
    }
}
