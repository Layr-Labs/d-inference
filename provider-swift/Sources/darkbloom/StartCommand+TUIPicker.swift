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
    /// Enforces memory budget and shows two sections: downloaded and available.
    internal func runModelPicker(entries: [PickerEntry], memoryGb: Double) throws -> [Int] {
        let budget = memoryGb - Start.pickerOSReserveGb

        var cursorPos = 0
        var selected = [Bool](repeating: false, count: entries.count)

        let downloadedCount = entries.filter(\.downloaded).count
        let availableCount = entries.count - downloadedCount

        // Enable raw terminal mode.
        var oldTermios = termios()
        tcgetattr(STDIN_FILENO, &oldTermios)
        var raw = oldTermios
        raw.c_lflag &= ~UInt(ECHO | ICANON | ISIG)
        raw.c_cc.16 = 1  // VMIN = 1 byte minimum
        raw.c_cc.17 = 0  // VTIME = no timeout
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw)

        // Ensure terminal is restored on any exit path.
        defer {
            // Show cursor, restore terminal.
            write(STDOUT_FILENO, "\u{1B}[?25h", 6)
            tcsetattr(STDIN_FILENO, TCSAFLUSH, &oldTermios)
        }

        // Hide cursor.
        write(STDOUT_FILENO, "\u{1B}[?25l", 6)

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
        if let idx = entries.firstIndex(where: { $0.downloaded && canFitIndividually($0) }) {
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
                output += "  \(ansiDim)\(count) selected \u{00B7} \(formattedGB(used)) GB total \u{00B7} all models can be served simultaneously\(ansiReset)\r\n\r\n"
            } else {
                output += "  \(ansiDim)\(count) selected \u{00B7} \(formattedGB(used)) GB on disk \u{00B7} \(ansiReset)\(ansiYellow)one model active at a time (swap on demand)\(ansiReset)\r\n\r\n"
            }
            lines += 2

            var idx = 0

            // Section 1: Downloaded models.
            if downloadedCount > 0 {
                output += "  \u{1B}[1mReady to serve:\u{1B}[0m\r\n"
                lines += 1
                for entry in entries where entry.downloaded {
                    let arrow = idx == pos ? "\u{25B8}" : " "
                    let check = sel[idx] ? "\u{2713}" : " "
                    let highlight = idx == pos ? "\u{1B}[36m" : ""
                    let reset = highlight.isEmpty ? "" : "\u{1B}[0m"
                    // A downloaded model that exceeds this box's budget is shown
                    // (it IS on disk) but flagged "won't fit" — never hidden.
                    let warn = canFitIndividually(entry) ? "" : " \u{26A0} won't fit"
                    output += "    \(highlight)\(arrow) [\(check)] \(entry.displayName) (\(formattedGB(entry.sizeGb)) GB)\(warn)\(reset)\r\n"
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
                    output += "    \(highlight)\(arrow) [\(check)] \u{2193} \(entry.displayName) (\(formattedGB(entry.sizeGb)) GB)\(note)\u{1B}[0m\r\n"
                    lines += 1
                    idx += 1
                }
            }

            // Write the full frame in one syscall.
            output.withCString { ptr in
                _ = write(STDOUT_FILENO, ptr, strlen(ptr))
            }

            return lines
        }

        // Initial render.
        lastLineCount = render(pos: cursorPos, sel: selected, prevLines: 0)

        // Input loop.
        var buf = [UInt8](repeating: 0, count: 3)
        while true {
            let n = read(STDIN_FILENO, &buf, 3)
            guard n > 0 else { continue }

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
}
