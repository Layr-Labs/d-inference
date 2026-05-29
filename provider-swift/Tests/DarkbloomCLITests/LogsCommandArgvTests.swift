import Testing

@testable import darkbloom

/// Unit tests for the pure `log` argv builders used by `darkbloom logs`.
///
/// These assert the two bug fixes:
///   1. `--debug` is forwarded to the underlying `log` tool.
///   2. `--last` + `--follow` reuses the same predicate/style for both the
///      historical (`showArgv`) and live (`streamArgv`) phases.
@Suite("Logs argv builders")
struct LogsCommandArgvTests {
    /// Matches the subsystem predicate the command builds internally.
    static let predicate = #"subsystem == "dev.darkbloom.provider""#

    // MARK: - streamArgv

    @Test("streamArgv(debug:false) uses --level info and no --debug")
    func streamArgvDefault() {
        let argv = Logs.streamArgv(predicate: Self.predicate, debug: false)

        // Shared base argv.
        #expect(argv.contains("log"))
        #expect(argv.contains("stream"))
        #expect(argv.contains("--predicate"))
        #expect(argv.contains(Self.predicate))
        #expect(argv.contains("--style"))
        #expect(argv.contains("ndjson"))

        // Non-debug => `--level info`, and never the bare `--debug` flag.
        #expect(argv.contains("--level"))
        #expect(argv.contains("info"))
        #expect(argvHasPair(argv, "--level", "info"))
        #expect(!argv.contains("--debug"))
    }

    @Test("streamArgv(debug:true) uses --level debug")
    func streamArgvDebug() {
        let argv = Logs.streamArgv(predicate: Self.predicate, debug: true)

        #expect(argv.contains("--level"))
        #expect(argv.contains("debug"))
        #expect(argvHasPair(argv, "--level", "debug"))

        // debug stream is `--level debug`, not the bare `--debug` flag, and the
        // default `info` level must not also be present.
        #expect(!argv.contains("info"))
        #expect(!argv.contains("--debug"))
    }

    // MARK: - showArgv

    @Test("showArgv(debug:false) has --info, --last, duration, no --debug")
    func showArgvDefault() {
        let argv = Logs.showArgv(predicate: Self.predicate, duration: "10m", debug: false)

        // Shared base argv.
        #expect(argv.contains("log"))
        #expect(argv.contains("show"))
        #expect(argv.contains("--predicate"))
        #expect(argv.contains(Self.predicate))
        #expect(argv.contains("--style"))
        #expect(argv.contains("ndjson"))

        // Historical window: `--info --last 10m`, no debug.
        #expect(argv.contains("--info"))
        #expect(argv.contains("--last"))
        #expect(argv.contains("10m"))
        #expect(argvHasPair(argv, "--last", "10m"))
        #expect(!argv.contains("--debug"))
    }

    @Test("showArgv(debug:true) also appends --debug")
    func showArgvDebug() {
        let argv = Logs.showArgv(predicate: Self.predicate, duration: "1h", debug: true)

        // `--info` is kept and `--debug` is added alongside it.
        #expect(argv.contains("--info"))
        #expect(argv.contains("--last"))
        #expect(argv.contains("1h"))
        #expect(argvHasPair(argv, "--last", "1h"))
        #expect(argv.contains("--debug"))
    }
}

/// Returns true if `first` appears immediately before `second` in `argv`.
/// Used to assert option/value adjacency (e.g. `--level debug`).
private func argvHasPair(_ argv: [String], _ first: String, _ second: String) -> Bool {
    guard let index = argv.firstIndex(of: first), index + 1 < argv.count else {
        return false
    }
    return argv[index + 1] == second
}
