import Darwin
import Foundation
import ProviderCore
import Testing

@testable import darkbloom

/// Drives the raw-mode model picker with scripted key presses. Input comes
/// from a datagram socket pair, so each key press arrives as one read, as it
/// does from a terminal. Output goes to a temporary file. The real terminal is
/// never touched: terminal-mode calls on a socket fail and change nothing.
@Suite("Start TUI model picker")
struct ModelPickerTerminalTests {
    private static let enter: [UInt8] = [0x0D]
    private static let lineFeed: [UInt8] = [0x0A]
    private static let space: [UInt8] = [0x20]
    private static let quit: [UInt8] = [0x71]
    private static let escape: [UInt8] = [0x1B]
    private static let up: [UInt8] = [0x1B, 0x5B, 0x41]
    private static let down: [UInt8] = [0x1B, 0x5B, 0x42]
    private static let right: [UInt8] = [0x1B, 0x5B, 0x43]

    private static let ansiReset = "\u{1B}[0m"
    private static let ansiDim = "\u{1B}[2m"
    private static let ansiYellow = "\u{1B}[33m"
    private static let ansiCyan = "\u{1B}[36m"
    private static let ansiDimRed = "\u{1B}[2;31m"

    /// `sizeGb` is the load estimate the picker budgets with. `downloadGb`
    /// is the catalog size shown for rows to download; it defaults to the
    /// load estimate.
    private func entry(
        _ name: String,
        sizeGb: Double,
        downloadGb: Double? = nil,
        downloaded: Bool,
        resumable: Bool = false
    ) -> Start.PickerEntry {
        let id = "fixture/\(name.lowercased().replacingOccurrences(of: " ", with: "-"))"
        return Start.PickerEntry(
            id: id,
            catalogModel: CatalogModel(id: id, s3Name: id, displayName: name, sizeGb: downloadGb ?? sizeGb),
            displayName: name,
            sizeGb: sizeGb,
            minRamGb: nil,
            downloaded: downloaded,
            resumable: resumable
        )
    }

    /// The tests use a 32 GB Mac. `Start.pickerLoadBudgetGiB` gives about
    /// 22.3 GiB for it (a 28.8 GiB cap less 6.5 GiB load headroom). The
    /// `budgetSitsBetweenTheFixtureSizes` test checks that every fixture size
    /// below is on the side of the budget that the tests expect.
    private static let memoryGb = 32.0

    /// Six rows: two downloaded, four to download.
    private var mixedEntries: [Start.PickerEntry] {
        [
            entry("Big Ready", sizeGb: 30, downloaded: true),
            entry("Small Ready", sizeGb: 8, downloaded: true),
            entry("Fits Later", sizeGb: 6, downloadGb: 5.4, downloaded: false),
            entry("Huge Partial", sizeGb: 40, downloaded: false, resumable: true),
            entry("Small Partial", sizeGb: 5, downloaded: false, resumable: true),
            entry("Huge New", sizeGb: 50, downloaded: false),
        ]
    }

    private struct PickerRun {
        let selection: [Int]
        let output: String

        /// Number of full frames the picker wrote.
        var frameCount: Int {
            output.components(separatedBy: "  Select models (RAM: ").count - 1
        }
    }

    private func runPicker(
        entries: [Start.PickerEntry],
        preselectDownloaded: Bool = true,
        keys: [[UInt8]]
    ) throws -> PickerRun {
        var sockets: [Int32] = [-1, -1]
        try #require(socketpair(AF_UNIX, SOCK_DGRAM, 0, &sockets) == 0)
        defer {
            close(sockets[0])
            close(sockets[1])
        }
        var bufferSize: Int32 = 64 * 1024
        let optionLength = socklen_t(MemoryLayout<Int32>.size)
        _ = setsockopt(sockets[0], SOL_SOCKET, SO_RCVBUF, &bufferSize, optionLength)
        _ = setsockopt(sockets[1], SOL_SOCKET, SO_SNDBUF, &bufferSize, optionLength)

        // Two extra 'q' presses end the loop if a script does not, so a wrong
        // script fails an assertion instead of blocking the test run.
        for key in keys + [Self.quit, Self.quit] {
            let written = key.withUnsafeBytes { write(sockets[1], $0.baseAddress, $0.count) }
            try #require(written == key.count)
        }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("model-picker-\(UUID().uuidString).out")
        let outputFD = open(outputURL.path, O_RDWR | O_CREAT | O_TRUNC, 0o600)
        try #require(outputFD >= 0)
        defer {
            close(outputFD)
            try? FileManager.default.removeItem(at: outputURL)
        }

        let start = try Start.parse([])
        let selection = try start.runModelPicker(
            entries: entries,
            memoryGb: Self.memoryGb,
            preselectDownloaded: preselectDownloaded,
            inputFD: sockets[0],
            outputFD: outputFD
        )
        let output = String(decoding: try Data(contentsOf: outputURL), as: UTF8.self)
        return PickerRun(selection: selection, output: output)
    }

    @Test("the 32 GB budget sits between the fixture sizes that fit and those that do not")
    func budgetSitsBetweenTheFixtureSizes() throws {
        let budget = Start.pickerLoadBudgetGiB(memoryGb: Self.memoryGb)
        // Single rows that must fit: 3, 4, 5, 6, 8 and 12 GiB.
        // Rows that must not fit: 30, 40 and 50 GiB.
        // Selections that must fit together: 8, 11 and 7 GiB.
        // A selection that must not fit together: 12 + 12 = 24 GiB.
        try #require(budget >= 12 && budget < 24, "budget \(budget) GiB")
    }

    @Test("Enter confirms the largest downloaded model that fits, which is preselected")
    func enterConfirmsPreselection() throws {
        let run = try runPicker(entries: mixedEntries, keys: [Self.enter])

        #expect(run.selection == [1])
        #expect(run.frameCount == 1)
        #expect(run.output.hasPrefix("\u{1B}[?25l\r\u{1B}[J"))
        #expect(run.output.hasSuffix("\u{1B}[?25h"))
    }

    @Test("the first frame shows both sections and marks rows that do not fit")
    func firstFrameLayout() throws {
        let run = try runPicker(entries: mixedEntries, keys: [Self.escape])
        let expectedFrame =
            "\r\u{1B}[J"
            + "  Select models (RAM: 32 GB)  \u{2191}\u{2193} navigate \u{00B7} Space toggle \u{00B7} Enter confirm\r\n"
            + "  \(Self.ansiDim)1 selected \u{00B7} 8.0 GiB load estimate \u{00B7} models are loaded as capacity allows\(Self.ansiReset)\r\n\r\n"
            + "  \u{1B}[1mDownloaded:\u{1B}[0m\r\n"
            + "    \(Self.ansiCyan)\u{25B8} [ ] Big Ready (~30.0 GiB load) \u{26A0} won't fit\(Self.ansiReset)\r\n"
            + "      [\u{2713}] Small Ready (~8.0 GiB load)\r\n"
            + "\r\n"
            + "  \u{1B}[1mAvailable to download:\u{1B}[0m\r\n"
            + "    \(Self.ansiDim)  [ ] \u{2193} Fits Later (5.4 GB download; ~6.0 GiB load)\u{1B}[0m\r\n"
            + "    \(Self.ansiDimRed)  [ ] \u{2193} Huge Partial (40.0 GB download; ~40.0 GiB load) \u{21BB} resuming \u{00B7} \u{26A0} exceeds RAM\u{1B}[0m\r\n"
            + "    \(Self.ansiDim)  [ ] \u{2193} Small Partial (5.0 GB download; ~5.0 GiB load) \u{21BB} resuming\u{1B}[0m\r\n"
            + "    \(Self.ansiDimRed)  [ ] \u{2193} Huge New (50.0 GB download; ~50.0 GiB load) \u{26A0} exceeds RAM\u{1B}[0m\r\n"

        #expect(run.selection == [])
        #expect(run.output == "\u{1B}[?25l" + expectedFrame + "\u{1B}[?25h")
    }

    @Test("arrow keys move the cursor, Space toggles, and rows that do not fit stay unselected")
    func navigateAndToggle() throws {
        let keys = [
            Self.down, Self.space,  // cursor 1: unselect Small Ready
            Self.down, Self.space,  // cursor 2: select Fits Later
            Self.down, Self.space,  // cursor 3: Huge Partial does not fit, no change
            Self.down, Self.space,  // cursor 4: select Small Partial
            Self.lineFeed,
        ]
        let run = try runPicker(entries: mixedEntries, keys: keys)

        #expect(run.selection == [2, 4])
        #expect(run.frameCount == 9)
        // Each redraw first moves up over the 12 lines of the previous frame.
        #expect(run.output.components(separatedBy: "\u{1B}[12A\r\u{1B}[J").count - 1 == 8)

        let lastFrame = try #require(run.output.components(separatedBy: "\u{1B}[12A").last)
        #expect(lastFrame.contains(
            "2 selected \u{00B7} 11.0 GiB load estimate \u{00B7} models are loaded as capacity allows"))
        #expect(lastFrame.contains("      [ ] Small Ready (~8.0 GiB load)\r\n"))
        #expect(lastFrame.contains("\(Self.ansiDim)  [\u{2713}] \u{2193} Fits Later (5.4 GB download; ~6.0 GiB load)"))
        #expect(lastFrame.contains("\(Self.ansiDimRed)  [ ] \u{2193} Huge Partial (40.0 GB download; ~40.0 GiB load)"))
        #expect(lastFrame.contains(
            "\(Self.ansiYellow)\u{25B8} [\u{2713}] \u{2193} Small Partial (5.0 GB download; ~5.0 GiB load) \u{21BB} resuming\u{1B}[0m"))
    }

    @Test("Space on a downloaded model that does not fit leaves it unselected")
    func wontFitDownloadedCannotBeSelected() throws {
        let run = try runPicker(
            entries: mixedEntries, keys: [Self.space, Self.enter])

        #expect(run.selection == [1])
        let lastFrame = try #require(run.output.components(separatedBy: "\u{1B}[12A").last)
        #expect(lastFrame.contains("\u{25B8} [ ] Big Ready (~30.0 GiB load) \u{26A0} won't fit"))
    }

    @Test("a selection larger than the budget reports that models may share memory or take turns")
    func overBudgetSelectionSwapsOnDemand() throws {
        let entries = [
            entry("Ready A", sizeGb: 12, downloaded: true),
            entry("Ready B", sizeGb: 12, downloaded: true),
        ]
        let run = try runPicker(
            entries: entries, keys: [Self.down, Self.space, Self.enter])

        #expect(run.selection == [0, 1])
        #expect(run.output.contains(
            "  \(Self.ansiDim)2 selected \u{00B7} 24.0 GiB load estimate \u{00B7} \(Self.ansiReset)"
                + "\(Self.ansiYellow)selected models may share memory or take turns\(Self.ansiReset)\r\n\r\n"))
        #expect(!run.output.contains("Available to download:"))
        // Two ready rows plus the three header lines and the section title.
        #expect(run.output.contains("\u{1B}[6A\r\u{1B}[J"))
    }

    @Test("Enter with nothing selected does not confirm, and q cancels")
    func enterNeedsASelection() throws {
        let entries = [
            entry("Remote One", sizeGb: 4, downloaded: false),
            entry("Remote Two", sizeGb: 3, downloaded: false),
        ]
        let run = try runPicker(entries: entries, keys: [Self.enter, Self.quit])

        #expect(run.selection == [])
        #expect(run.frameCount == 2)
        #expect(!run.output.contains("Downloaded:"))
        #expect(run.output.contains("0 selected \u{00B7} 0.0 GiB load estimate"))
        #expect(run.output.contains(
            "\r\n\r\n  \u{1B}[1mAvailable to download:\u{1B}[0m\r\n"
                + "    \(Self.ansiYellow)\u{25B8} [ ] \u{2193} Remote One (4.0 GB download; ~4.0 GiB load)\u{1B}[0m\r\n"))
    }

    @Test("Escape cancels even when a model is selected")
    func escapeCancelsSelection() throws {
        let run = try runPicker(entries: mixedEntries, keys: [Self.escape])
        #expect(run.selection == [])
        #expect(run.frameCount == 1)
    }

    @Test("the cursor stops at both ends and unknown keys only redraw")
    func cursorBoundsAndIgnoredKeys() throws {
        let entries = [
            entry("Ready A", sizeGb: 4, downloaded: true),
            entry("Ready B", sizeGb: 3, downloaded: true),
        ]
        let keys: [[UInt8]] = [
            Self.up,  // already at the top
            Self.right,  // not an up or down arrow
            [0x78],  // 'x'
            [0x1B, 0x5B],  // incomplete escape sequence
            Self.down,
            Self.down,  // already at the bottom
            Self.space,  // select Ready B
            Self.enter,
        ]
        let run = try runPicker(entries: entries, keys: keys)

        #expect(run.selection == [0, 1])
        #expect(run.frameCount == 8)
        let lastFrame = try #require(run.output.components(separatedBy: "\u{1B}[6A").last)
        #expect(lastFrame.contains("      [\u{2713}] Ready A (~4.0 GiB load)\r\n"))
        #expect(lastFrame.contains("    \(Self.ansiCyan)\u{25B8} [\u{2713}] Ready B (~3.0 GiB load)\(Self.ansiReset)\r\n"))
        #expect(lastFrame.contains("2 selected \u{00B7} 7.0 GiB load estimate"))
    }

    @Test("without preselection nothing starts selected, so Enter does not confirm")
    func noPreselection() throws {
        let run = try runPicker(
            entries: mixedEntries, preselectDownloaded: false, keys: [Self.enter, Self.quit])

        #expect(run.selection == [])
        #expect(run.frameCount == 2)
        #expect(run.output.contains("0 selected \u{00B7} 0.0 GiB load estimate"))
        #expect(run.output.contains("      [ ] Small Ready (~8.0 GiB load)\r\n"))
    }
}
