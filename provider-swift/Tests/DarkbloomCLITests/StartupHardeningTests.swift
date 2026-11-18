import DarkbloomProcessHardening
import Darwin
import Foundation
import Testing

/// Anchor for `Bundle(for:)`, as in `CLIDispatchTests`.
private final class StartupHardeningBundleAnchor {}

/// Every shipped executable removes the exception handlers it was started
/// with before it does anything else. Each case starts the REAL built binary
/// from a launcher that holds a handler, as any process that starts one can,
/// and reads the binary's own record (`--report-startup-hardening`, which only
/// inspects this process): the handler must have reached it, and none may be
/// left. Nothing reads another process's memory.
@Suite(.serialized) struct StartupHardeningTests {
    /// The executables built beside this test bundle (the cluster worker and
    /// planner are built by their own package; their entry order is checked
    /// below from source).
    static let builtExecutables = ["darkbloom", "darkbloom-enclave", "darkbloom-fan-helper"]

    /// Never raised on Apple silicon, so the test process can hold them while
    /// it starts a child without catching its own faults.
    static let neverRaised = exception_mask_t(EXC_MASK_RPC_ALERT) | exception_mask_t(EXC_MASK_EMULATION)

    @Test(arguments: builtExecutables)
    func handlerInheritedFromTheLauncherIsRemovedAtLaunch(executable: String) throws {
        let report = try Self.run(executable, handing: .inheritedFromLauncher(Self.neverRaised))
        try Self.expectRemoved(Self.neverRaised, by: report, executable)
    }

    @Test(arguments: builtExecutables)
    func handlerForEveryExceptionTypeIsRemovedAtLaunch(executable: String) throws {
        let every = InheritedExceptionPorts.everyException
        let report = try Self.run(executable, handing: .setAtSpawn(every))
        try Self.expectRemoved(every, by: report, executable)
    }

    /// The removal is `main`'s first statement, so no key, prompt, answer or
    /// model can exist in a process that still has a handler it did not choose.
    @Test(arguments: StartupEntry.shipped)
    func removalIsTheFirstStatementOfMain(entry: StartupEntry) throws {
        let first = try entry.firstStatement()
        #expect(first.contains("ProcessStartupHardening.applyAtLaunch()"),
                "\(entry.path): main must remove inherited handlers first; it starts with: \(first)")
    }

    // MARK: - Launching

    enum Hand: Sendable {
        /// The test process installs the handler on itself and starts the child
        /// with Foundation, which inherits it.
        case inheritedFromLauncher(exception_mask_t)
        /// `posix_spawnattr_setexceptionports_np`: the handler is the child's
        /// from its first instruction.
        case setAtSpawn(exception_mask_t)
    }

    struct Report {
        let fields: [String: Any]
        func bool(_ key: String) -> Bool? { fields[key] as? Bool }
        func mask(_ key: String) -> exception_mask_t? { (fields[key] as? Int).map { exception_mask_t($0) } }
    }

    static func expectRemoved(_ mask: exception_mask_t, by report: Report, _ executable: String) throws {
        // The harness itself: the handler did reach the child (its startup
        // record, or what it holds now when it recorded none).
        let reached = try #require(report.mask("inherited_task") ?? report.mask("remaining_task"),
                                   "\(executable) reported no handlers: \(report.fields)")
        #expect(reached & mask == mask, "\(executable) did not inherit the test handler: \(report.fields)")
        #expect(report.mask("remaining_task") == 0,
                "\(executable) still has a task handler it was started with: \(report.fields)")
        #expect(report.mask("remaining_thread") == 0, "\(executable) still has a thread handler: \(report.fields)")
        #expect(report.bool("applied") == true, "\(executable) did not run the startup removal: \(report.fields)")
        #expect(report.bool("clean") == true, "\(executable): \(report.fields)")
    }

    static func run(_ executable: String, handing hand: Hand) throws -> Report {
        let anchor = Bundle(for: StartupHardeningBundleAnchor.self).bundleURL
        let products = anchor.pathExtension == "xctest" ? anchor.deletingLastPathComponent() : anchor
        let binary = products.appendingPathComponent(executable)
        try #require(FileManager.default.isExecutableFile(atPath: binary.path), "\(binary.path) is not built")
        let port = try ReceiveRight()
        defer { port.destroy() }
        let output: Data
        switch hand {
        case .inheritedFromLauncher(let mask):
            output = try port.whileHandling(mask) { try runInheriting(binary) }
        case .setAtSpawn(let mask):
            output = try spawn(binary, handler: port.name, mask: mask)
        }
        let line = String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let object = try JSONSerialization.jsonObject(with: Data(line.utf8))
        return Report(fields: try #require(object as? [String: Any], "\(executable) printed: \(line)"))
    }

    private static func runInheriting(_ binary: URL) throws -> Data {
        let process = Process()
        process.executableURL = binary
        process.arguments = [ProcessStartupHardening.reportArgument]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        return data
    }

    /// The child is the handler's only sender; the read is bounded so a child
    /// that faulted into the unanswered handler fails the test instead of
    /// hanging it.
    private static func spawn(_ binary: URL, handler: mach_port_t, mask: exception_mask_t) throws -> Data {
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        try #require(posix_spawnattr_setexceptionports_np(&attributes, mask, handler,
                                                          exception_behavior_t(EXCEPTION_DEFAULT),
                                                          thread_state_flavor_t(THREAD_STATE_NONE)) == 0)
        var pipe: [Int32] = [0, 0]
        try #require(Darwin.pipe(&pipe) == 0)
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, pipe[1], STDOUT_FILENO)
        posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addclose(&actions, pipe[0])
        posix_spawn_file_actions_addclose(&actions, pipe[1])
        var pid: pid_t = 0
        let arguments = [binary.path, ProcessStartupHardening.reportArgument]
        var argv = arguments.map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        let spawned = posix_spawn(&pid, binary.path, &actions, &attributes, &argv, environ)
        close(pipe[1])
        defer { close(pipe[0]) }
        try #require(spawned == 0, "posix_spawn failed: \(spawned)")
        let output = OutputReader(FileHandle(fileDescriptor: pipe[0], closeOnDealloc: false))
        let finished = output.wait(seconds: 60)
        if !finished { kill(pid, SIGKILL) }
        var status: Int32 = 0
        waitpid(pid, &status, 0)
        try #require(finished, "\(binary.lastPathComponent) did not report within 60 s")
        #expect(status == 0)
        return output.data
    }

    /// Reads a child's output to its end on another thread.
    final class OutputReader: @unchecked Sendable {
        private let done = DispatchSemaphore(value: 0)
        private(set) var data = Data()

        init(_ handle: FileHandle) {
            DispatchQueue.global().async { [self] in
                data = handle.readDataToEndOfFile()
                done.signal()
            }
        }

        /// True when the output ended in time; `data` is complete only then.
        func wait(seconds: Int) -> Bool { done.wait(timeout: .now() + .seconds(seconds)) == .success }
    }

    /// A receive right of the test process, with one send right for handlers.
    final class ReceiveRight {
        let name: mach_port_t

        init() throws {
            var name = mach_port_t(MACH_PORT_NULL)
            try #require(mach_port_allocate(mach_task_self_, MACH_PORT_RIGHT_RECEIVE, &name) == KERN_SUCCESS)
            try #require(mach_port_insert_right(mach_task_self_, name, name,
                                                mach_msg_type_name_t(MACH_MSG_TYPE_MAKE_SEND)) == KERN_SUCCESS)
            self.name = name
        }

        /// Installs this port as the test process's handler for `mask` while
        /// `body` runs, then puts the previous handlers back.
        func whileHandling<T>(_ mask: exception_mask_t, _ body: () throws -> T) throws -> T {
            let capacity = Int(EXC_TYPES_COUNT)
            var masks = [exception_mask_t](repeating: 0, count: capacity)
            var ports = [mach_port_t](repeating: mach_port_t(MACH_PORT_NULL), count: capacity)
            var behaviors = [exception_behavior_t](repeating: 0, count: capacity)
            var flavors = [thread_state_flavor_t](repeating: 0, count: capacity)
            var count = mach_msg_type_number_t(capacity)
            try #require(task_swap_exception_ports(mach_task_self_, mask, name, exception_behavior_t(EXCEPTION_DEFAULT),
                                                   thread_state_flavor_t(THREAD_STATE_NONE), &masks, &count, &ports,
                                                   &behaviors, &flavors) == KERN_SUCCESS)
            defer {
                task_set_exception_ports(mach_task_self_, mask, mach_port_t(MACH_PORT_NULL),
                                         exception_behavior_t(EXCEPTION_DEFAULT), thread_state_flavor_t(THREAD_STATE_NONE))
                for index in 0 ..< Int(count) {
                    task_set_exception_ports(mach_task_self_, masks[index], ports[index], behaviors[index], flavors[index])
                    if ports[index] != mach_port_t(MACH_PORT_NULL) { mach_port_deallocate(mach_task_self_, ports[index]) }
                }
            }
            return try body()
        }

        func destroy() {
            mach_port_mod_refs(mach_task_self_, name, MACH_PORT_RIGHT_SEND, -1)
            mach_port_mod_refs(mach_task_self_, name, MACH_PORT_RIGHT_RECEIVE, -1)
        }
    }
}

/// A shipped executable's entry point, read from source.
struct StartupEntry: Sendable, CustomTestStringConvertible {
    /// Relative to the repository root.
    let path: String
    /// nil: top-level code (`main.swift`); otherwise the line that opens `main`.
    let mainDeclaration: String?

    static let shipped = [
        StartupEntry(path: "provider-swift/Sources/darkbloom/main.swift", mainDeclaration: nil),
        StartupEntry(path: "provider-swift/Sources/DarkbloomFanHelper/main.swift", mainDeclaration: nil),
        StartupEntry(path: "provider-swift/Sources/darkbloom-enclave-cli/EnclaveCLI.swift",
                     mainDeclaration: "static func main() {"),
        StartupEntry(path: "libs/darkbloom-cluster-worker/Sources/DarkbloomClusterWorker/WorkerMain.swift",
                     mainDeclaration: "static func main() {"),
        StartupEntry(path: "libs/darkbloom-cluster-worker/Sources/PlacementPlan/PlacementPlan.swift",
                     mainDeclaration: "static func main() {"),
    ]

    var testDescription: String { path }

    /// The first line of code that runs: after imports and compiler
    /// directives for top-level code, else the first line inside `main`.
    func firstStatement() throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
        var lines = source.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        if let mainDeclaration {
            let start = try #require(lines.firstIndex(of: mainDeclaration), "\(path) has no `\(mainDeclaration)`")
            lines = Array(lines[(start + 1)...])
        }
        let code = lines.first { line in
            !line.isEmpty && !line.hasPrefix("//") && !line.hasPrefix("import ") && !line.hasPrefix("#")
        }
        return try #require(code, "\(path) has no code")
    }
}
