import DarkbloomProcessHardening
import Darwin
import Foundation
import Testing

/// Anchor for `Bundle(for:)`, as in `CLIDispatchTests`.
private final class StartupHardeningBundleAnchor {}

/// Every shipped executable removes the exception handlers it was started
/// with before it does anything else. Each case starts the REAL built binary
/// from a launcher that holds a handler and reads the binary's own record
/// (`--report-startup-hardening`, which only inspects that process): the
/// handler must have reached it, and none may be left. Nothing reads another
/// process's memory.
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

    /// An abort right after startup reaches no handler of the launcher. One
    /// case per entry point that handles keys, prompts or answers (the held
    /// binary stops before it runs the command, so the command has no effect
    /// on this Mac). A delivered message is destroyed unread.
    @Test(arguments: AbortEntry.all)
    func abortAfterStartupReachesNoHandler(entry: AbortEntry) throws {
        let ending = try Self.abortAfterStartup(entry)
        #expect(ending.deliveredMessageIDs.isEmpty,
                "\(entry): an exception message reached the launcher's handler: \(ending.deliveredMessageIDs)")
        #expect(ending.endedBySignal == SIGABRT, "\(entry) was not ended by the abort: \(ending)")
        let record = try #require(try JSONSerialization.jsonObject(with: Data(ending.startupRecord.utf8)) as? [String: Any],
                                  "\(entry) startup record: \(ending.startupRecord)")
        // The harness itself: the launcher's handler did reach the child.
        let reached = (record["inherited_task"] ?? record["remaining_task"]) as? Int
        let every = Int(InheritedExceptionPorts.everyException)
        #expect(reached.map { $0 & every == every } == true, "\(entry) did not get the test handler: \(record)")
        #expect(record["clean"] as? Bool == true, "\(entry) startup record: \(record)")
    }

    /// The removal is `main`'s first statement, so no key, prompt, answer or
    /// model can exist in a process that still has a handler it did not choose.
    @Test(arguments: StartupEntry.shipped)
    func removalIsTheFirstStatementOfMain(entry: StartupEntry) throws {
        let first = try entry.firstStatement()
        let call = "ProcessStartupHardening.applyAtLaunch()"
        #expect(first == call || (first.hasPrefix("let ") && first.hasSuffix(" = \(call)")),
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
                                                          thread_state_flavor_t(THREAD_STATE_NONE)) == 0
                     && posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT)) == 0)
        let pipe = try Self.closeOnExecPipe()
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
        // The reader owns the read end and closes it when its read is over.
        let output = OutputReader(FileHandle(fileDescriptor: pipe[0], closeOnDealloc: true))
        try #require(spawned == 0, "posix_spawn failed: \(spawned)")
        let finished = output.wait(seconds: 60)
        if !finished { kill(pid, SIGKILL) }
        var status: Int32 = 0
        waitpid(pid, &status, 0)
        try #require(finished, "\(binary.lastPathComponent) did not report within 60 s")
        #expect(status == 0)
        return output.data
    }

    struct Ending: CustomStringConvertible {
        let startupRecord: String
        let deliveredMessageIDs: [mach_msg_id_t]
        let endedBySignal: Int32?
        var description: String {
            "record \(startupRecord), delivered \(deliveredMessageIDs), signal \(endedBySignal.map(String.init) ?? "none")"
        }
    }

    /// `EXCEPTION_IDENTITY_PROTECTED | MACH_EXCEPTION_CODES`.
    static let protectedIdentityBehavior = exception_behavior_t(bitPattern: 0x8000_0004)

    /// Starts `entry` holding a handler for every exception type, waits for its
    /// startup record (`holdEnvironmentKey`: it prints it and waits), sends
    /// SIGABRT and collects any exception message the handler receives.
    static func abortAfterStartup(_ entry: AbortEntry) throws -> Ending {
        let anchor = Bundle(for: StartupHardeningBundleAnchor.self).bundleURL
        let products = anchor.pathExtension == "xctest" ? anchor.deletingLastPathComponent() : anchor
        let binary = products.appendingPathComponent(entry.executable)
        try #require(FileManager.default.isExecutableFile(atPath: binary.path), "\(binary.path) is not built")
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("startup-hardening-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let port = try ReceiveRight()
        defer { port.destroy() }

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        try #require(posix_spawnattr_setexceptionports_np(&attributes, InheritedExceptionPorts.everyException, port.name,
                                                          protectedIdentityBehavior,
                                                          thread_state_flavor_t(THREAD_STATE_NONE)) == 0)
        // The test runner may block or ignore SIGABRT; the child must not inherit that.
        var unblocked = sigset_t()
        var defaults = sigset_t()
        sigemptyset(&unblocked); sigemptyset(&defaults)
        sigaddset(&defaults, SIGABRT)
        try #require(posix_spawnattr_setflags(&attributes,
                                              Int16(POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_CLOEXEC_DEFAULT)) == 0
                     && posix_spawnattr_setsigmask(&attributes, &unblocked) == 0
                     && posix_spawnattr_setsigdefault(&attributes, &defaults) == 0)
        let pipe = try closeOnExecPipe()
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, pipe[1], STDOUT_FILENO)
        posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addclose(&actions, pipe[0])
        posix_spawn_file_actions_addclose(&actions, pipe[1])
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = home.path
        environment["DARKBLOOM_NO_UPDATE_CHECK"] = "1"
        environment[ProcessStartupHardening.holdEnvironmentKey] = "1"
        var envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { envp.forEach { free($0) } }
        var argv = ([binary.path] + entry.arguments).map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        var pid: pid_t = 0
        let spawned = posix_spawn(&pid, binary.path, &actions, &attributes, &argv, &envp)
        close(pipe[1])
        // The reader owns the read end and closes it when its read is over.
        let firstLine = FirstLineReader(FileHandle(fileDescriptor: pipe[0], closeOnDealloc: true))
        try #require(spawned == 0, "posix_spawn failed: \(spawned)")

        guard let record = firstLine.wait(seconds: 60) else {
            kill(pid, SIGKILL)
            port.destroy()
            var status: Int32 = 0
            waitpid(pid, &status, 0)
            Issue.record("\(entry) printed no startup record within 60 s")
            return Ending(startupRecord: "", deliveredMessageIDs: [], endedBySignal: nil)
        }
        kill(pid, SIGABRT)
        var delivered: [mach_msg_id_t] = []
        var status: Int32 = 0
        var exited = false
        let deadline = Date().addingTimeInterval(30)
        while !exited && Date() < deadline {
            if let id = port.receive(timeoutMilliseconds: 100) {
                delivered.append(id)
                // The child waits for the handler's answer; without the port it goes on.
                port.destroy()
            }
            exited = waitpid(pid, &status, WNOHANG) == pid
            if port.isDestroyed && !exited { usleep(20_000) }
        }
        if !exited {
            port.destroy()
            kill(pid, SIGKILL)
            waitpid(pid, &status, 0)
        }
        let signaled = (status & 0x7f) != 0 && (status & 0x7f) != 0x7f
        return Ending(startupRecord: record, deliveredMessageIDs: delivered, endedBySignal: signaled ? status & 0x7f : nil)
    }

    /// A pipe whose ends no other child of the test runner inherits.
    static func closeOnExecPipe() throws -> [Int32] {
        var pipe: [Int32] = [0, 0]
        try #require(Darwin.pipe(&pipe) == 0)
        for end in pipe { _ = fcntl(end, F_SETFD, FD_CLOEXEC) }
        return pipe
    }

    /// Reads a child's first output line on another thread.
    final class FirstLineReader: @unchecked Sendable {
        private let done = DispatchSemaphore(value: 0)
        private var line: String?

        init(_ handle: FileHandle) {
            DispatchQueue.global().async { [self] in
                var bytes = Data()
                while true {
                    let chunk = handle.readData(ofLength: 1)
                    guard let byte = chunk.first, byte != UInt8(ascii: "\n") else { break }
                    bytes.append(byte)
                }
                line = String(decoding: bytes, as: UTF8.self)
                done.signal()
            }
        }

        /// The line, or nil when none ended within `seconds`.
        func wait(seconds: Int) -> String? {
            done.wait(timeout: .now() + .seconds(seconds)) == .success ? line : nil
        }
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

        /// One message's id, destroyed unread (its port rights released), or
        /// nil when none arrived in time.
        func receive(timeoutMilliseconds: mach_msg_timeout_t) -> mach_msg_id_t? {
            guard !destroyed else { return nil }
            let size = 4096
            let buffer = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 8)
            defer { buffer.deallocate() }
            let header = buffer.bindMemory(to: mach_msg_header_t.self, capacity: 1)
            let result = mach_msg(header, MACH_RCV_MSG | MACH_RCV_TIMEOUT, 0, mach_msg_size_t(size), name,
                                  timeoutMilliseconds, mach_port_t(MACH_PORT_NULL))
            guard result == MACH_MSG_SUCCESS else { return nil }
            let id = header.pointee.msgh_id
            mach_msg_destroy(header)
            return id
        }

        private var destroyed = false
        var isDestroyed: Bool { destroyed }

        func destroy() {
            guard !destroyed else { return }
            destroyed = true
            mach_port_mod_refs(mach_task_self_, name, MACH_PORT_RIGHT_SEND, -1)
            mach_port_mod_refs(mach_task_self_, name, MACH_PORT_RIGHT_RECEIVE, -1)
        }
    }
}

/// An entry point that handles keys, prompts or answers, as the provider or a
/// pair starts it.
struct AbortEntry: Sendable, CustomTestStringConvertible {
    let executable: String
    let arguments: [String]

    static let all = [
        // The launchd daemon (`LaunchAgent.serviceProgramArguments`).
        AbortEntry(executable: "darkbloom", arguments: ["start", "--foreground"]),
        // Only me in a terminal.
        AbortEntry(executable: "darkbloom", arguments: ["start", "--local", "--here"]),
        // A pair member's owner of its rank worker.
        AbortEntry(executable: "darkbloom", arguments: ["cluster", "worker-owner"]),
        AbortEntry(executable: "darkbloom-enclave", arguments: ["attest"]),
        AbortEntry(executable: "darkbloom-fan-helper", arguments: []),
    ]

    var testDescription: String { ([executable] + arguments).joined(separator: " ") }
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

    /// The first line of code that runs: after imports for top-level code,
    /// else the first line inside `main`. A conditional-compilation block or
    /// a block comment before it is refused rather than read past, so the
    /// check cannot be satisfied by a line that is not compiled.
    func firstStatement() throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
        var lines = source.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        if let mainDeclaration {
            let start = try #require(lines.firstIndex(of: mainDeclaration), "\(path) has no `\(mainDeclaration)`")
            lines = Array(lines[(start + 1)...])
        }
        var inImportConditional = false
        for line in lines where !line.isEmpty && !line.hasPrefix("//") {
            // `#if canImport(...) / import ... / #endif` around an import is still an import.
            if line.hasPrefix("#if canImport(") { inImportConditional = true; continue }
            if inImportConditional && line == "#endif" { inImportConditional = false; continue }
            if line.hasPrefix("import ") || line.hasPrefix("@preconcurrency import ") { continue }
            try #require(!line.hasPrefix("#") && !line.contains("/*") && !line.contains(";") && !inImportConditional,
                         "\(path): `\(line)` comes before the first statement")
            return line
        }
        Issue.record("\(path) has no code")
        return ""
    }
}
