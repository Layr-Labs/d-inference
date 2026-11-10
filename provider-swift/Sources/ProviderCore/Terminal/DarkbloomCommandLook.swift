import Foundation
import Darwin

/// The Darkbloom look of the everyday commands (`darkbloom start`, `stop`, `restart`, `status`, `update`): the mark
/// beside a one-line title as a command opens, and the one-row live line, its petal turning, while it waits.
///
/// The rules are the cluster setup's (`ClusterOnboardingTerminal`): standard input and output on a terminal, NO_COLOR
/// unset and TERM not dumb, block glyphs (a UTF-8 locale) and at least 40 columns; the mark blooms and the petal turns
/// unless DARKBLOOM_NO_ANIMATION or CI is set. Anywhere else it writes nothing, so a script or a log keeps every byte.
/// Look only: the command's own lines are said through `plain`, exactly as without it; the next said line replaces the
/// live line, which moves below it. The live line never hides the cursor or changes the terminal's mode, so no way out,
/// a signal included, has anything to put back; a return or a throw also clears the live line.
public final class DarkbloomCommandLook: @unchecked Sendable {
    /// What the terminal allows.
    public struct Mode: Equatable, Sendable {
        /// The mark and the live line show.
        public var decorates: Bool
        /// The mark blooms and the live line's petal turns.
        public var animates: Bool
        /// The window's width in columns (0 when unknown).
        public var columns: Int

        public init(decorates: Bool, animates: Bool, columns: Int) {
            self.decorates = decorates; self.animates = animates && decorates; self.columns = columns
        }

        public static let plain = Mode(decorates: false, animates: false, columns: 0)

        /// The cluster setup's rules for these terminals, window and environment.
        public static func of(inputIsTerminal: Bool, outputIsTerminal: Bool, columns: Int,
                              environment: [String: String]) -> Mode {
            let decorates = ClusterOnboardingTerminal.supportsColor(inputIsTerminal: inputIsTerminal,
                outputIsTerminal: outputIsTerminal, environment: environment)
                && ClusterOnboardingBrand.drawsBlocks(environment) && columns >= 40
            return Mode(decorates: decorates,
                        animates: environment["DARKBLOOM_NO_ANIMATION"] == nil && environment["CI"] == nil,
                        columns: columns)
        }

        /// This process's standard input and output.
        public static func standard(environment: [String: String] = ProcessInfo.processInfo.environment) -> Mode {
            var window = winsize()
            let columns = ioctl(STDOUT_FILENO, TIOCGWINSZ, &window) == 0 ? Int(window.ws_col) : 0
            return of(inputIsTerminal: isatty(STDIN_FILENO) == 1, outputIsTerminal: isatty(STDOUT_FILENO) == 1,
                      columns: columns, environment: environment)
        }
    }

    public let mode: Mode
    private let colour: String
    private let output: @Sendable (String) -> Void
    private let pause: @Sendable (UInt32) -> Void
    /// The window's width now: a window made narrower while the live line shows must not wrap it.
    private let width: @Sendable () -> Int
    private let lock = NSLock()
    private var opened = false
    private var live: String?
    private var drawnFrame = -1
    private var ticker: DispatchSourceTimer?

    /// The look whose live line shows now: `say(_:plain:)` steers a command's lines round it.
    nonisolated(unsafe) private static var showing: DarkbloomCommandLook?
    private static let showingLock = NSLock()

    /// `output` writes decorations (raw, after the command's buffered lines); `pause` spaces the bloom's frames.
    public init(mode: Mode, environment: [String: String] = ProcessInfo.processInfo.environment,
                output: @escaping @Sendable (String) -> Void = DarkbloomCommandLook.writeToStandardOutput,
                pause: @escaping @Sendable (UInt32) -> Void = { usleep($0) },
                width: (@Sendable () -> Int)? = nil) {
        self.mode = mode
        colour = ClusterOnboardingBrand.colour(environment)
        self.output = output; self.pause = pause
        let columns = mode.columns
        self.width = width ?? { columns }
    }

    /// Standard output's width now, or `fallback` when it can't be read.
    public static func standardOutputColumns(fallback: Int) -> Int {
        var window = winsize()
        return ioctl(STDOUT_FILENO, TIOCGWINSZ, &window) == 0 && window.ws_col > 0 ? Int(window.ws_col) : fallback
    }

    deinit { ticker?.cancel() }

    /// Tests give the commands a look of their own.
    @TaskLocal public static var forTesting: DarkbloomCommandLook?

    /// A command's look: this process's terminal, by the setup's rules; plain for a command run inside another.
    public static func forCommand() -> DarkbloomCommandLook {
        if insideAnotherCommand { return DarkbloomCommandLook(mode: .plain) }
        if let forTesting { return forTesting }
        let mode = Mode.standard()
        return DarkbloomCommandLook(mode: mode, width: { standardOutputColumns(fallback: mode.columns) })
    }

    /// Runs a command inside another command (`unenroll` runs `stop --solo`, `autopilot enable` runs `start`) with a
    /// plain look: the mark appears once, at the top of the command the person ran, never partway through.
    public static func runNested<T>(_ body: () async throws -> T) async rethrows -> T {
        try await $insideAnotherCommand.withValue(true) { try await body() }
    }

    @TaskLocal private static var insideAnotherCommand = false

    // MARK: - The mark

    /// The command's opening, once: the mark beside `title` (its first word bold, the rest dim), blooming where it
    /// animates. Nothing where the look doesn't decorate, or where the row would not fit the window.
    public func open(_ title: String) {
        lock.withLock {
            guard mode.decorates, !opened, 2 + ClusterOnboardingBrand.width + 3 + title.count < mode.columns else { return }
            opened = true
            output("\n")
            guard mode.animates else { output(Self.mark(title, revealed: Int.max, colour: colour) + "\n"); return }
            for (index, revealed) in ClusterOnboardingBrand.frames.enumerated() {
                output((index > 0 ? "\u{1B}[\(ClusterOnboardingBrand.height)A" : "") + Self.mark(title, revealed: revealed, colour: colour))
                pause(55_000)
            }
            output("\n")
        }
    }

    /// The mark's rows with the first `revealed` pixels of the bloom drawn, `title` beside its second row.
    static func mark(_ title: String, revealed: Int, colour: String) -> String {
        let words = title.split(separator: " ", maxSplits: 1).map(String.init)
        let heading = "\u{1B}[1m\(words.first ?? title)\u{1B}[0m" + (words.count > 1 ? " \u{1B}[2m\(words[1])\u{1B}[0m" : "")
        let beside = ["", heading, "", ""]
        return zip(ClusterOnboardingBrand.rows(revealed: revealed), beside).map { row, text in
            "  \u{1B}[\(colour)m\(row)\u{1B}[0m" + (text.isEmpty ? "" : "   " + text)
        }.joined(separator: "\n") + "\n"
    }

    // MARK: - The live line

    /// `body` with the live line under the command's last line: a turning petal and `text`. It is cleared when `body`
    /// ends, however it ends, leaving the cursor where the next line starts. Plain (or within another live line):
    /// `body` alone.
    public func working<T>(_ text: String, _ body: () async throws -> T) async rethrows -> T {
        guard begin(text) else { return try await body() }
        defer { end() }
        return try await body()
    }

    /// `working` for a body that doesn't suspend.
    public func working<T>(_ text: String, _ body: () throws -> T) rethrows -> T {
        guard begin(text) else { return try body() }
        defer { end() }
        return try body()
    }

    /// `line` said through `plain` (the command's own print), the live line out of its way and drawn again below it.
    public func say(_ line: String, plain: (String) -> Void) {
        lock.lock(); defer { lock.unlock() }
        guard live != nil else { plain(line); return }
        output("\r\u{1B}[J")
        plain(line)
        draw(force: true)
    }

    /// `line` said through `plain`, round the live line that shows now, if any (a command's helpers say their lines here).
    public static func say(_ line: String, plain: (String) -> Void) {
        guard let look = showingLock.withLock({ showing }) else { plain(line); return }
        look.say(line, plain: plain)
    }

    private func begin(_ text: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard mode.decorates, live == nil, claimShowing() else { return false }
        live = text
        draw(force: true)
        guard mode.animates else { return true }
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "darkbloom.command-look"))
        timer.schedule(deadline: .now() + .milliseconds(125), repeating: .milliseconds(125))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.lock.withLock { self.draw(force: false) }
        }
        ticker = timer
        timer.resume()
        return true
    }

    private func end() {
        lock.lock(); defer { lock.unlock() }
        ticker?.cancel(); ticker = nil
        live = nil; drawnFrame = -1
        Self.showingLock.withLock { if Self.showing === self { Self.showing = nil } }
        output("\r\u{1B}[J")
    }

    /// Makes this look the one whose live line shows, unless one already does: checked and set in one step, so two
    /// looks never show a live line at once.
    private func claimShowing() -> Bool {
        Self.showingLock.withLock {
            guard Self.showing == nil else { return false }
            Self.showing = self
            return true
        }
    }

    /// The live row again when `force`, or when the petal turned. The lock is held.
    private func draw(force: Bool) {
        guard let text = live else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        let frame = mode.animates ? Int((now / 125_000_000) % UInt64(ClusterOnboardingBrand.spinner.count)) : 0
        guard force || frame != drawnFrame else { return }
        drawnFrame = frame
        // Line wrap is off while the row is written (`ClusterOnboardingBrand.noWrap`), in the same write as the row.
        output("\r\u{1B}[J" + ClusterOnboardingBrand.noWrap
            + Self.liveRow(text, petal: ClusterOnboardingBrand.spinner[frame], colour: colour, columns: width()) + ClusterOnboardingBrand.wrap)
    }

    /// One row only, as the setup's live line: the return and erase that replace it reach just the cursor's row, so a
    /// wrapped line would leave its start behind. Room: the indent, petal and space, the ellipsis and the last column.
    static func liveRow(_ text: String, petal: String, colour: String, columns: Int) -> String {
        let fitted = ClusterOnboardingBrand.liveText(text, room: max(1, columns - 6))
        return "  \u{1B}[\(colour)m\(petal)\u{1B}[0m \u{1B}[2m\(fitted)\u{2026}\u{1B}[0m"
    }

    /// Writes `text` to standard output in as few `write(2)` calls as possible, after flushing stdio, so it lands
    /// below every line the command printed first.
    public static let writeToStandardOutput: @Sendable (String) -> Void = { text in
        fflush(stdout)
        var bytes = Array(text.utf8)[...]
        while !bytes.isEmpty {
            let written = bytes.withUnsafeBytes { Darwin.write(STDOUT_FILENO, $0.baseAddress, $0.count) }
            if written < 0 {
                if errno == EINTR || errno == EAGAIN { continue }
                return
            }
            bytes = bytes.dropFirst(written)
        }
    }
}
