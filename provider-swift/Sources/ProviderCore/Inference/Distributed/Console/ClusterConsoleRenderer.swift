import Foundation

/// One full screen, fitted to a terminal size: never more lines than rows,
/// never a line wider than the columns, and no byte the screen did not mean
/// to send.
public struct ClusterConsoleFrame: Equatable, Sendable {
    public let lines: [ClusterConsoleLine]
    /// The furthest the body can scroll at this size.
    public let maximumScroll: Int
    /// Rows the body occupies.
    public let bodyRows: Int

    /// The screen as plain text, one line per row.
    public var text: String { lines.map(\.text).joined(separator: "\n") }

    /// The bytes that draw this frame over the previous one: home, then each
    /// row cleared and written, then everything below cleared.
    public func terminalBytes(color: Bool, rows: Int) -> [UInt8] {
        var output = "\u{1B}[H"
        for (index, line) in lines.enumerated() {
            if index > 0 { output += "\r\n" }
            output += "\u{1B}[K"
            let code = color ? Self.code(line.style) : nil
            output += (code.map { "\u{1B}[\($0)m" } ?? "") + line.text + (code == nil ? "" : "\u{1B}[0m")
        }
        // Rows below the frame still hold the previous one.
        if lines.count < rows { output += (lines.isEmpty ? "" : "\r\n") + "\u{1B}[J" }
        return Array(output.utf8)
    }

    private static func code(_ style: ClusterConsoleLine.Style) -> String? {
        switch style {
        case .title, .heading: return "1"
        case .good: return "32"
        case .warning: return "33"
        case .bad: return "31"
        case .dim: return "2"
        case .prompt: return "7"
        case .normal: return nil
        }
    }
}

public enum ClusterConsoleRenderer {
    /// Below this the screen says only that it needs more room.
    static let minimumColumns = 28
    static let minimumRows = 6
    /// Text is not stretched across a very wide window.
    static let maximumTextColumns = 132

    public static func frame(_ state: ClusterConsoleState) -> ClusterConsoleFrame {
        let columns = max(state.size.columns, 0), rows = max(state.size.rows, 0)
        guard columns >= minimumColumns, rows >= minimumRows else {
            let lines = ["darkbloom cluster", "The window is too small.", "q closes."]
                .prefix(rows).map { ClusterConsoleLine(clip($0, columns), .normal, indent: 0) }
            return .init(lines: columns > 0 ? Array(lines) : [], maximumScroll: 0, bodyRows: 0)
        }
        let width = min(columns, maximumTextColumns)
        let body = ClusterConsoleContent.body(state).flatMap { wrap($0, width: width) }
        // Header, body, status line, key line.
        let bodyRows = rows - 3
        let maximumScroll = max(body.count - bodyRows, 0)
        let offset = min(max(state.scroll, 0), maximumScroll)
        var lines = [header(state, width: width, position: maximumScroll > 0 ? (offset, bodyRows, body.count) : nil)]
        lines += body.dropFirst(offset).prefix(bodyRows)
        lines += Array(repeating: .blank, count: rows - 2 - lines.count)
        lines.append(statusLine(state, width: width))
        // One column short: writing the last cell of the last row scrolls some terminals.
        lines.append(.init(clip(keys(state), width - 1), .dim, indent: 0))
        return .init(lines: lines, maximumScroll: maximumScroll, bodyRows: bodyRows)
    }

    // MARK: - Fixed rows

    private static func header(_ state: ClusterConsoleState, width: Int, position: (Int, Int, Int)?) -> ClusterConsoleLine {
        var parts = ["Darkbloom cluster"]
        if let snapshot = state.snapshot {
            parts.append(snapshot.saved.pairing.map { "cluster \($0.clusterID)" } ?? "no saved setup")
            parts.append("link \(snapshot.link.state.rawValue)")
            parts.append("read \(snapshot.observedAt)")
        }
        if state.options.dryRun { parts.append("dry run") }
        let title = sanitized(parts.joined(separator: " \u{B7} "))
        guard let (offset, shown, total) = position else { return .init(clip(title, width), .title, indent: 0) }
        // Where the body is scrolled to stays visible however narrow the window is.
        let place = "lines \(offset + 1)-\(min(offset + shown, total)) of \(total)"
        let room = max(width - place.count - 2, 0), left = clip(title, room)
        return .init(clip(left + String(repeating: " ", count: max(width - left.count - place.count, 1)) + place, width), .title, indent: 0)
    }

    /// The one row that answers "what is happening now": a question waiting
    /// for a key, a refusal, an action in flight, or a refresh.
    private static func statusLine(_ state: ClusterConsoleState, width: Int) -> ClusterConsoleLine {
        let text: String, style: ClusterConsoleLine.Style
        if let action = state.confirming {
            (text, style) = (question(action, state), .prompt)
        } else if let notice = state.notice {
            (text, style) = (notice, .warning)
        } else if let action = state.inFlight {
            (text, style) = ("\(action.title) is running; its result appears under Activity.", .warning)
        } else if state.refreshing {
            (text, style) = ("Reading this Mac's state.", .dim)
        } else {
            (text, style) = ("", .normal)
        }
        return .init(clip(sanitized(text), width), style, indent: 0)
    }

    private static func question(_ action: ClusterConsoleAction, _ state: ClusterConsoleState) -> String {
        switch action {
        case .approveSetup:
            let peer = state.snapshot?.candidate?.pairing?.peerID ?? "the peer"
            return "Save this setup and trust \(peer) by the host key shown? y approves; any other key cancels."
        case .startSession:
            return "Start the distributed session? Both Macs load the model. y starts; any other key cancels."
        case .recoverJournal:
            return "Clear the device journal if its owner and worker are both gone? y recovers; any other key cancels."
        case .fixLink, .stopSession, .exportDiagnostics:
            return "\(action.title)? y confirms; any other key cancels."
        }
    }

    private static func keys(_ state: ClusterConsoleState) -> String {
        state.showsHelp ? "? back   q close"
            : "r refresh  f fix link  a approve  s start  x stop  c recover  e export  ? help  q close"
    }

    // MARK: - Fitting text

    /// Printable ASCII and a few single-width marks pass; anything else,
    /// including every control character, becomes a question mark, so text
    /// from a file or a child process cannot move the cursor or widen a row.
    static func sanitized(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.map { scalar in
            (0x20...0x7E).contains(scalar.value) || allowedMarks.contains(scalar.value) ? scalar : "?"
        }))
    }

    private static let allowedMarks: Set<UInt32> = [0xB7, 0x2013, 0x2014, 0x2018, 0x2019, 0x201C, 0x201D, 0x2026, 0x2192]

    static func clip(_ text: String, _ width: Int) -> String {
        width <= 0 ? "" : String(text.prefix(width))
    }

    /// Breaks at spaces, keeps the line's indent on every row, and splits a
    /// word only when it is wider than the row.
    static func wrap(_ line: ClusterConsoleLine, width: Int) -> [ClusterConsoleLine] {
        let indent = min(line.indent, max(width - 8, 0))
        let room = max(width - indent, 1), margin = String(repeating: " ", count: indent)
        var rows = [String](), current = ""
        for word in sanitized(line.text).split(separator: " ", omittingEmptySubsequences: false) {
            var word = String(word)
            if !current.isEmpty, current.count + 1 + word.count <= room {
                current += " " + word
                continue
            }
            if !current.isEmpty { rows.append(current); current = "" }
            while word.count > room {
                rows.append(String(word.prefix(room)))
                word = String(word.dropFirst(room))
            }
            current = word
        }
        rows.append(current)
        return rows.map { .init(margin + $0, line.style, indent: 0) }
    }
}
