// Start TUI model picker: raw-mode terminal multi-select rendering + input loop.
import Foundation
import ArgumentParser
import ProviderCore
#if canImport(Darwin)
import Darwin
#endif

extension Start {
    // MARK: - TUI Model Picker

    /// Interactive multi-select model picker using raw terminal mode.
    /// Arrow keys navigate, Space toggles selection, Enter confirms, Esc/q cancels.
    /// Input that ends (the terminal closed) or can no longer be read cancels too.
    /// Enforces memory budget and shows two sections: downloaded and available.
    /// `inputFD` and `outputFD` default to the terminal; tests pass other descriptors.
    internal func runModelPicker(
        entries: [PickerEntry],
        memoryGb: Double,
        preselectDownloaded: Bool = true,
        inputFD: Int32 = STDIN_FILENO,
        outputFD: Int32 = STDOUT_FILENO
    ) throws -> [Int] {
        let budget = Start.pickerLoadBudgetGiB(memoryGb: memoryGb)

        var cursorPos = 0
        var selected = [Bool](repeating: false, count: entries.count)

        let downloadedCount = entries.filter(\.downloaded).count
        let availableCount = entries.count - downloadedCount

        // Enable raw terminal mode.
        var oldTermios = termios()
        tcgetattr(inputFD, &oldTermios)
        var raw = oldTermios
        raw.c_lflag &= ~UInt(ECHO | ICANON | ISIG)
        raw.c_cc.16 = 1  // VMIN = 1 byte minimum
        raw.c_cc.17 = 0  // VTIME = no timeout
        tcsetattr(inputFD, TCSAFLUSH, &raw)

        // Ensure terminal is restored on any exit path.
        defer {
            // Show cursor, restore terminal.
            write(outputFD, "\u{1B}[?25h", 6)
            tcsetattr(inputFD, TCSAFLUSH, &oldTermios)
        }

        // Hide cursor.
        write(outputFD, "\u{1B}[?25l", 6)

        var lastLineCount: Int = 0

        let ansiReset = "\u{1B}[0m"
        let ansiDim = "\u{1B}[2m"
        let ansiYellow = "\u{1B}[33m"

        func formattedGB(_ value: Double) -> String {
            String(format: "%.1f", value)
        }

        func canFitIndividually(_ entry: PickerEntry) -> Bool {
            Start.modelFitsBudget(sizeGb: entry.sizeGb, memoryGb: memoryGb)
        }

        // Pre-select the largest downloaded model that can fit on this machine.
        if preselectDownloaded, let idx = entries.firstIndex(where: { $0.downloaded && canFitIndividually($0) }) {
            selected[idx] = true
        }

        /// Render the picker UI, returning the number of lines written.
        func render(pos: Int, sel: [Bool], prevLines: Int) -> Int {
            var output = ""

            // Move cursor up to overwrite previous render.
            if prevLines > 0 {
                output += "\u{1B}[\(prevLines)A"
            }
            // Carriage return + clear to end of screen.
            output += "\r\u{1B}[J"

            let used: Double = entries.enumerated()
                .filter { sel[$0.offset] }
                .map(\.element.sizeGb)
                .reduce(0, +)
            let count = sel.filter { $0 }.count
            let fitsSimultaneously = used <= budget

            var lines = 0

            output += "  Select models (RAM: \(Int(memoryGb)) GB)  \u{2191}\u{2193} navigate \u{00B7} Space toggle \u{00B7} Enter confirm\r\n"
            lines += 1

            if fitsSimultaneously {
                output += "  \(ansiDim)\(count) selected \u{00B7} \(formattedGB(used)) GiB load estimate \u{00B7} models are loaded as capacity allows\(ansiReset)\r\n\r\n"
            } else {
                output += "  \(ansiDim)\(count) selected \u{00B7} \(formattedGB(used)) GiB load estimate \u{00B7} \(ansiReset)\(ansiYellow)selected models may share memory or take turns\(ansiReset)\r\n\r\n"
            }
            lines += 2

            var idx = 0

            // Section 1: Downloaded models.
            if downloadedCount > 0 {
                output += "  \u{1B}[1mDownloaded:\u{1B}[0m\r\n"
                lines += 1
                for entry in entries where entry.downloaded {
                    let arrow = idx == pos ? "\u{25B8}" : " "
                    let check = sel[idx] ? "\u{2713}" : " "
                    let highlight = idx == pos ? "\u{1B}[36m" : ""
                    let reset = highlight.isEmpty ? "" : "\u{1B}[0m"
                    // A downloaded model that exceeds this box's budget is shown
                    // (it IS on disk) but flagged "won't fit" — never hidden.
                    let warn = canFitIndividually(entry) ? "" : " \u{26A0} won't fit"
                    output += "    \(highlight)\(arrow) [\(check)] \(entry.displayName) (~\(formattedGB(entry.sizeGb)) GiB load)\(warn)\(reset)\r\n"
                    lines += 1
                    idx += 1
                }
            }

            // Section 2: Not-downloaded models.
            if availableCount > 0 {
                if downloadedCount > 0 {
                    output += "\r\n"
                    lines += 1
                }
                output += "  \u{1B}[1mAvailable to download:\u{1B}[0m\r\n"
                lines += 1
                for entry in entries where !entry.downloaded {
                    let arrow = idx == pos ? "\u{25B8}" : " "
                    let check = sel[idx] ? "\u{2713}" : " "
                    let tooLargeForMachine = !canFitIndividually(entry)
                    let highlight: String
                    if idx == pos {
                        highlight = "\u{1B}[33m"
                    } else if tooLargeForMachine {
                        highlight = "\u{1B}[2;31m"
                    } else {
                        highlight = "\u{1B}[2m"
                    }
                    let note: String
                    if entry.resumable {
                        note = tooLargeForMachine ? " \u{21BB} resuming \u{00B7} \u{26A0} exceeds RAM" : " \u{21BB} resuming"
                    } else {
                        note = tooLargeForMachine ? " \u{26A0} exceeds RAM" : ""
                    }
                    output += "    \(highlight)\(arrow) [\(check)] \u{2193} \(entry.displayName) (\(formattedGB(entry.catalogModel.sizeGb)) GB download; ~\(formattedGB(entry.sizeGb)) GiB load)\(note)\u{1B}[0m\r\n"
                    lines += 1
                    idx += 1
                }
            }

            // Write the full frame in one syscall.
            output.withCString { ptr in
                _ = write(outputFD, ptr, strlen(ptr))
            }

            return lines
        }

        // Initial render.
        lastLineCount = render(pos: cursorPos, sel: selected, prevLines: 0)

        // Input loop.
        var buf = [UInt8](repeating: 0, count: 3)
        while true {
            let n = read(inputFD, &buf, 3)
            if n < 0, Self.waitToRetryPickerRead(on: inputFD, after: errno) { continue }
            guard n > 0 else {
                // No key can arrive any more: the input ended (the terminal
                // went away) or the read failed for good. Cancel, as Esc does.
                print()
                return []
            }

            if n == 1 {
                switch buf[0] {
                case 0x1B:
                    // Bare Escape — cancel.
                    print()
                    return []
                case 0x71: // 'q'
                    print()
                    return []
                case 0x20: // Space — toggle selection.
                    if selected[cursorPos] {
                        selected[cursorPos] = false
                    } else {
                        // Allow selection if the model individually fits in memory.
                        // Multiple models can be selected even if their total exceeds
                        // available RAM — only one will be warm (loaded) at a time;
                        // the coordinator manages model swaps on demand.
                        if canFitIndividually(entries[cursorPos]) {
                            selected[cursorPos] = true
                        }
                    }
                case 0x0A, 0x0D: // Enter — confirm.
                    if selected.contains(true) {
                        print()
                        return selected.enumerated()
                            .filter(\.element)
                            .map(\.offset)
                    }
                    // Don't allow confirm with nothing selected.
                default:
                    break
                }
            } else if n == 3, buf[0] == 0x1B, buf[1] == 0x5B {
                // Arrow key escape sequence: ESC [ A/B/C/D
                switch buf[2] {
                case 0x41: // Up
                    if cursorPos > 0 { cursorPos -= 1 }
                case 0x42: // Down
                    if cursorPos < entries.count - 1 { cursorPos += 1 }
                default:
                    break
                }
            }

            lastLineCount = render(pos: cursorPos, sel: selected, prevLines: lastLineCount)
        }
    }

    /// Decides whether a failed read of the picker's input is repeated, and
    /// waits first when the retry needs it. A read that a signal interrupted
    /// is repeated at once. A non-blocking descriptor with nothing to read yet
    /// is repeated once it is readable; waiting here is what keeps that retry
    /// from spinning. Any other failure will not clear, so the picker must
    /// stop reading.
    private static func waitToRetryPickerRead(on inputFD: Int32, after readError: Int32) -> Bool {
        switch readError {
        case EINTR:
            return true
        case EAGAIN:
            var input = pollfd(fd: inputFD, events: Int16(POLLIN), revents: 0)
            // The repeated read reports whatever ended the wait. A wait that
            // cannot be made at all would turn the retry back into a spin.
            return poll(&input, 1, -1) >= 0 || errno == EINTR
        default:
            return false
        }
    }
}
