import Foundation

/// One full wizard screen fitted to a terminal size: never more lines than
/// rows, never a line wider than the columns, and no byte it did not mean to
/// send. Lines are made of spans so a key, a tick or a warning can carry its
/// own colour; without colour the same text is drawn plain.
public struct ClusterSetupFrame: Equatable, Sendable {
    public enum Style: Equatable, Sendable { case normal, title, heading, good, warning, bad, dim, accent, key, prompt, selected }

    public struct Span: Equatable, Sendable {
        public let text: String
        public let style: Style
        public init(_ text: String, _ style: Style = .normal) { self.text = text; self.style = style }
    }

    public struct Line: Equatable, Sendable {
        public let spans: [Span]
        /// The wired row this line states something from, or the screen's own furniture.
        public let source: ClusterConsoleLine.Source
        public init(_ spans: [Span], from source: ClusterConsoleLine.Source) { self.spans = spans; self.source = source }
        public init(_ text: String, _ style: Style = .normal, from source: ClusterConsoleLine.Source) {
            self.init([Span(text, style)], from: source)
        }
        public var text: String { spans.map(\.text).joined() }
        static let blank = Line("", from: .frame)
    }

    public let lines: [Line]
    public let maximumScroll: Int
    public let bodyRows: Int
    /// The question this frame shows in full; nil when none is open.
    public let question: ClusterSetupState.Question?

    public var text: String { lines.map(\.text).joined(separator: "\n") }

    /// Home, each row cleared and written, then everything below cleared.
    public func terminalBytes(color: Bool, rows: Int) -> [UInt8] {
        var output = "\u{1B}[H"
        for (index, line) in lines.enumerated() {
            if index > 0 { output += "\r\n" }
            output += "\u{1B}[K"
            for span in line.spans {
                if color, let code = Self.code(span.style) { output += "\u{1B}[\(code)m" + span.text + "\u{1B}[0m" } else { output += span.text }
            }
        }
        if lines.count < rows { output += (lines.isEmpty ? "" : "\r\n") + "\u{1B}[J" }
        return Array(output.utf8)
    }

    private static func code(_ style: Style) -> String? {
        switch style {
        case .title: return "1"
        case .heading: return "1;36"
        case .good: return "32"
        case .warning: return "33"
        case .bad: return "31"
        case .dim: return "2"
        case .accent: return "36"
        case .key: return "1;36"
        case .prompt: return "7"
        case .selected: return "1;7"
        case .normal: return nil
        }
    }
}

/// The marks the screen draws with: Unicode where the terminal's locale is
/// UTF-8, plain ASCII otherwise. Every mark is one column wide.
public struct ClusterSetupGlyphs: Sendable, Equatable {
    public let done, current, blocked, todo, waiting, rule, full, empty, selected, bullet, arrow, open, close: String
    /// The step keys and the scroll keys, as the key line names them.
    public let leftRight, upDown: String
    public let spinner: [String]

    public static let unicode = ClusterSetupGlyphs(done: "✓", current: "●", blocked: "✗", todo: "○", waiting: "…", rule: "─",
        full: "█", empty: "░", selected: "▸", bullet: "•", arrow: "→", open: "▕", close: "▏", leftRight: "←→", upDown: "↑↓",
        spinner: ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"])
    public static let ascii = ClusterSetupGlyphs(done: "+", current: ">", blocked: "x", todo: "o", waiting: "~", rule: "-",
        full: "#", empty: ".", selected: ">", bullet: "*", arrow: "->", open: "[", close: "]", leftRight: "<-/->", upDown: "up/down",
        spinner: ["|", "/", "-", "\\"])

    /// UTF-8 when the locale the process runs in says so.
    public static func forEnvironment(_ environment: [String: String]) -> ClusterSetupGlyphs {
        let locale = environment["LC_ALL"].flatMap { $0.isEmpty ? nil : $0 } ?? environment["LC_CTYPE"].flatMap { $0.isEmpty ? nil : $0 }
            ?? environment["LANG"] ?? ""
        return locale.uppercased().replacingOccurrences(of: "-", with: "").contains("UTF8") ? .unicode : .ascii
    }

    /// The spinner's mark at a clock reading, ten frames a second.
    func spin(_ uptime: UInt64) -> String { spinner[Int((uptime / 100_000_000) % UInt64(spinner.count))] }

    /// Every mark, for the sanitizer.
    var marks: Set<String> {
        Set([done, current, blocked, todo, waiting, rule, full, empty, selected, bullet, arrow, open, close] + spinner
            + (leftRight + upDown).map(String.init))
    }
}

public enum ClusterSetupScreen {
    static let minimumColumns = 40
    static let minimumRows = 12
    static let maximumTextColumns = 120

    static func fits(_ size: ClusterConsoleSize) -> Bool { size.columns >= minimumColumns && size.rows >= minimumRows }

    /// Whether every word of a question shows on its row at this size.
    static func canShow(_ question: ClusterSetupState.Question, at size: ClusterConsoleSize) -> Bool {
        fits(size) && text(of: question, dryRun: false).count <= min(size.columns, maximumTextColumns) - 1
    }

    /// One row, both answers, short enough for an 80-column window.
    static func text(of question: ClusterSetupState.Question, dryRun: Bool) -> String {
        switch question {
        case .applyLinkFix: return "y: apply these commands (macOS asks once). Any other key: not now."
        case .confirmCode(let code): return "Do both screens show \(code.prefix(3)) \(code.suffix(3))? y: yes, n: no."
        case .confirmLinkCode(let code): return "Do both screens show \(code.prefix(3)) \(code.suffix(3))? y: yes, n: no."
        case .adoptPlan: return "y: save this plan here and send the other Mac its setup. Other key: no."
        case .approveInbox(let digest): return "y: save setup \(digest.prefix(12)) and trust its pinned key. Other key: no."
        case .runCheck: return "y: run the check (both Macs load the model briefly). Other key: no."
        case .startSession: return "y: start serving (both Macs load the model). Other key: no."
        }
    }

    public static func frame(_ state: ClusterSetupState, glyphs: ClusterSetupGlyphs = .unicode) -> ClusterSetupFrame {
        let columns = max(state.size.columns, 0), rows = max(state.size.rows, 0)
        guard fits(state.size) else {
            let lines = ["darkbloom cluster", "Window too small:", "\(minimumColumns)x\(minimumRows) at least.", "q closes."]
                .prefix(rows).map { ClusterSetupFrame.Line(clip($0, columns), from: .frame) }
            return .init(lines: columns > 0 ? Array(lines) : [], maximumScroll: 0, bodyRows: 0, question: nil)
        }
        let width = min(columns, maximumTextColumns)
        let content = state.showsHelp ? ClusterSetupContent.help(state, width: width, glyphs: glyphs)
            : ClusterSetupContent.body(state, width: width, glyphs: glyphs, interactive: true)
        let body = content.map { fit($0, width: width, glyphs: glyphs) }
        // Title, rail, rule, body, rule, status line, keys.
        let bodyRows = rows - 6
        let maximumScroll = max(body.count - bodyRows, 0)
        let offset = min(max(state.scroll, 0), maximumScroll)
        var lines = [title(state, width: width, glyphs: glyphs), rail(state, width: width, glyphs: glyphs),
                     fit(rule(state.showsHelp ? "Help: \(state.step.title)" : "\(state.step.number)  \(state.step.title)", width: width, glyphs: glyphs),
                         width: width, glyphs: glyphs)]
        lines += body.dropFirst(offset).prefix(bodyRows)
        lines += Array(repeating: .blank, count: max(0, 3 + bodyRows - lines.count))
        let position = maximumScroll > 0 ? "lines \(offset + 1)-\(min(offset + bodyRows, body.count)) of \(body.count), \(glyphs.upDown) scroll" : ""
        lines.append(fit(rule(position, width: width, glyphs: glyphs, dim: true), width: width, glyphs: glyphs))
        lines.append(status(state, width: width, glyphs: glyphs))
        // One column short: writing the last cell of the last row scrolls some terminals.
        lines.append(fit(keys(state, glyphs: glyphs), width: width - 1, glyphs: glyphs))
        return .init(lines: lines, maximumScroll: maximumScroll, bodyRows: bodyRows,
            question: state.asking.flatMap { canShow($0, at: state.size) ? $0 : nil })
    }

    // MARK: - Fixed rows

    private static func title(_ state: ClusterSetupState, width: Int, glyphs: ClusterSetupGlyphs) -> ClusterSetupFrame.Line {
        var right = [String]()
        if state.options.dryRun { right.append("dry run") }
        if let local = state.snapshot?.local { right.append("Darkbloom \(local.version)") }
        let left = " Darkbloom cluster setup"
        let tail = right.joined(separator: " \u{B7} ")
        let gap = max(1, width - left.count - tail.count - 1)
        return fit(.init([.init(left, .title), .init(String(repeating: " ", count: gap)), .init(tail, .dim)], from: .frame),
            width: width, glyphs: glyphs)
    }

    /// The six steps with where each stands. The step on screen is marked.
    private static func rail(_ state: ClusterSetupState, width: Int, glyphs: ClusterSetupGlyphs) -> ClusterSetupFrame.Line {
        var spans = [ClusterSetupFrame.Span(" ")]
        let full = ClusterSetupStep.allCases.map { " \(mark(state, $0, glyphs)) \($0.number) \($0.label) " }.joined(separator: " ").count + 1
        let compact = full > width
        for step in ClusterSetupStep.allCases {
            let status = state.snapshot == nil ? ClusterSetupStepStatus.waiting : state.status(of: step)
            let style: ClusterSetupFrame.Style
            switch status {
            case .done: style = .good
            case .blocked: style = .bad
            case .waiting: style = .dim
            case .todo: style = .normal
            }
            let label = compact && step != state.step ? "\(step.number)" : "\(step.number) \(step.label)"
            if step == state.step {
                spans.append(.init(" \(mark(state, step, glyphs)) \(label) ", .selected))
            } else {
                spans.append(.init(" \(mark(state, step, glyphs)) ", style))
                spans.append(.init("\(label) ", status == .waiting ? .dim : .normal))
            }
            if step != .serve { spans.append(.init(" ")) }
        }
        return fit(.init(spans, from: .frame), width: width, glyphs: glyphs)
    }

    static func mark(_ state: ClusterSetupState, _ step: ClusterSetupStep, _ glyphs: ClusterSetupGlyphs) -> String {
        guard state.snapshot != nil else { return glyphs.todo }
        switch state.status(of: step) {
        case .done: return glyphs.done
        case .blocked: return glyphs.blocked
        case .waiting: return glyphs.waiting
        case .todo: return step == state.step ? glyphs.current : glyphs.todo
        }
    }

    private static func rule(_ label: String, width: Int, glyphs: ClusterSetupGlyphs, dim: Bool = false) -> ClusterSetupFrame.Line {
        let lead = String(repeating: glyphs.rule, count: 2)
        let text = label.isEmpty ? "" : " \(label) "
        let rest = max(0, width - 2 - text.count)
        return .init([.init(lead, .dim), .init(text, dim ? .dim : .heading), .init(String(repeating: glyphs.rule, count: rest), .dim)], from: .frame)
    }

    /// The one row that says what is happening now.
    private static func status(_ state: ClusterSetupState, width: Int, glyphs: ClusterSetupGlyphs) -> ClusterSetupFrame.Line {
        if let question = state.asking {
            let text = canShow(question, at: state.size) ? self.text(of: question, dryRun: state.options.dryRun)
                : "Window too narrow to ask. Any key cancels."
            return fit(.init(" " + text, .prompt, from: .frame), width: width, glyphs: glyphs)
        }
        if let notice = state.notice { return fit(.init(" " + notice, .warning, from: .frame), width: width, glyphs: glyphs) }
        if let busy = busyText(state) {
            return fit(.init([.init(" \(glyphs.spin(state.now)) ", .accent), .init(busy, .dim)], from: .frame), width: width, glyphs: glyphs)
        }
        return .blank
    }

    static func busyText(_ state: ClusterSetupState) -> String? {
        if let action = state.inFlight { return "\(action.title)\u{2026}" }
        switch state.linkFix {
        case .previewing: return "Working out the exact commands (dry run, nothing changes)\u{2026}"
        case .applying: return "Applying the link fix: approve or cancel the macOS prompt\u{2026}"
        default: break
        }
        if case .running(let stage, _) = state.check { return "Check: \(stage.title)\u{2026}" }
        if case .reaching = state.peer { return "Reaching the other Mac over the pinned route\u{2026}" }
        if state.plans == .planning { return "Planning from both Macs' memory\u{2026}" }
        if case .sending = state.prompt { return "Waiting for the reply\u{2026}" }
        switch state.session {
        case .launching: return "Starting serving\u{2026}"
        case .stopping: return "Stopping: both Macs release their workers\u{2026}"
        default: break
        }
        if state.refreshing { return state.snapshot == nil ? "Reading this Mac\u{2026}" : "Reading again\u{2026}" }
        return nil
    }

    /// The keys that do something now, the step's one action first.
    static func keys(_ state: ClusterSetupState, glyphs: ClusterSetupGlyphs) -> ClusterSetupFrame.Line {
        var keys = [(String, String)]()
        if state.asking != nil {
            keys = [("y", "yes"), ("any key", "no")]
        } else if case .editing = state.prompt {
            keys = [("enter", "send"), ("esc", "close"), ("backspace", "delete")]
        } else if state.showsHelp {
            keys = [("?", "back"), (glyphs.upDown, "scroll"), ("q", "quit")]
        } else {
            if let primary = ClusterSetupContent.primaryLabel(state) { keys.append(("enter", primary)) }
            keys += ClusterSetupContent.stepKeys(state, glyphs: glyphs)
            keys += [(glyphs.leftRight, "steps"), ("r", "re-read"), ("?", "help"), ("q", "quit")]
        }
        var spans = [ClusterSetupFrame.Span(" ")]
        for (index, key) in keys.enumerated() {
            if index > 0 { spans.append(.init("  ")) }
            spans.append(.init(key.0, .key))
            spans.append(.init(" " + key.1, .dim))
        }
        return .init(spans, from: .frame)
    }

    // MARK: - Fitting

    /// Clips a line to `width` columns, span by span, and replaces anything
    /// that is not printable ASCII or one of the screen's own marks.
    static func fit(_ line: ClusterSetupFrame.Line, width: Int, glyphs: ClusterSetupGlyphs) -> ClusterSetupFrame.Line {
        var room = max(width, 0), spans = [ClusterSetupFrame.Span]()
        for span in line.spans where room > 0 {
            let text = clip(sanitized(span.text, glyphs: glyphs), room)
            room -= text.count
            if !text.isEmpty { spans.append(.init(text, span.style)) }
        }
        return .init(spans, from: line.source)
    }

    static func clip(_ text: String, _ width: Int) -> String { width <= 0 ? "" : String(text.prefix(width)) }

    private static let allowed: Set<UInt32> = [0xB7, 0x2013, 0x2014, 0x2018, 0x2019, 0x201C, 0x201D, 0x2026, 0x2190, 0x2191,
                                               0x2192, 0x2193, 0x24D8]

    static func sanitized(_ text: String, glyphs: ClusterSetupGlyphs) -> String {
        let marks = glyphs.marks
        return String(text.map { character -> Character in
            if marks.contains(String(character)) { return character }
            guard character.unicodeScalars.count == 1, let scalar = character.unicodeScalars.first else { return "?" }
            if (0x20...0x7E).contains(scalar.value) { return character }
            // Non-ASCII marks only where the screen itself draws Unicode.
            if glyphs == .unicode, allowed.contains(scalar.value) { return character }
            switch scalar.value {
            case 0x2018, 0x2019: return "'"
            case 0x201C, 0x201D: return "\""
            case 0x2013, 0x2014: return "-"
            case 0x2026: return "."
            case 0xB7: return "*"
            default: return "?"
            }
        })
    }

    /// Breaks text at spaces into rows of at most `width`, every row after
    /// the first indented by `hanging`.
    static func wrap(_ text: String, width: Int, hanging: Int = 0) -> [String] {
        let hanging = min(max(hanging, 0), max(width - 1, 0))
        let first = max(width, 1), rest = max(width - hanging, 1)
        var rows = [String](), current = ""
        func limit() -> Int { rows.isEmpty ? first : rest }
        for piece in text.split(separator: " ") {
            var word = String(piece)
            if !current.isEmpty {
                if current.count + 1 + word.count <= limit() { current += " " + word; continue }
                rows.append(current)
                current = ""
            }
            // A word wider than the row is split.
            while word.count > limit() {
                rows.append(String(word.prefix(limit())))
                word = String(word.dropFirst(limit()))
            }
            current = word
        }
        if !current.isEmpty || rows.isEmpty { rows.append(current) }
        return rows.enumerated().map { $0.offset == 0 ? $0.element : String(repeating: " ", count: hanging) + $0.element }
    }

    /// "12.4 GiB", "512 MiB".
    static func gib(_ bytes: Int) -> String {
        let value = Double(bytes) / 1_073_741_824
        if value >= 1024 { return String(format: "%.1f TiB", value / 1024) }
        if value >= 10 { return String(format: "%.0f GiB", value) }
        if value >= 1 { return String(format: "%.1f GiB", value) }
        return String(format: "%.0f MiB", Double(bytes) / 1_048_576)
    }

    /// "11.0 GiB": always one decimal, for figures compared with each other.
    static func gibTenths(_ bytes: Int) -> String { String(format: "%.1f GiB", Double(bytes) / 1_073_741_824) }

    /// A bar of `width` cells for `used` of `total`; more than full is drawn full.
    static func bar(_ used: Int, of total: Int, width: Int, glyphs: ClusterSetupGlyphs) -> String {
        guard total > 0, width > 0 else { return glyphs.open + String(repeating: glyphs.empty, count: max(width, 0)) + glyphs.close }
        let filled = min(width, max(used > 0 ? 1 : 0, Int((Double(used) / Double(total) * Double(width)).rounded())))
        return glyphs.open + String(repeating: glyphs.full, count: filled) + String(repeating: glyphs.empty, count: width - filled) + glyphs.close
    }
}
