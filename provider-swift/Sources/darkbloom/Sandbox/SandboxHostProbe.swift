import Darwin
import Foundation
import IOKit.ps
import Network
import ProviderCore

/// Measures `SandboxHostFacts` on this Mac with the same sources the add-on
/// sizes slots from: `hw.ncpu`, `hw.memsize` and `statfs` free blocks on the
/// add-on root's volume. Read-only; at most two short `pmset` reads.
enum SandboxHostProbe {
    static func live(addon: SandboxAddon, imagesInstalled: Bool) async -> SandboxHostFacts {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let space = volumeSpace(containing: addon.root)
        return SandboxHostFacts(
            chip: sysctlString("machdep.cpu.brand_string") ?? "an unknown chip",
            appleSilicon: sysctlInteger("hw.optional.arm64") == 1,
            macOSVersion: version.patchVersion == 0
                ? "\(version.majorVersion).\(version.minorVersion)"
                : "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)",
            macOSMajor: version.majorVersion,
            cores: Int(sysctlInteger("hw.ncpu") ?? Int64(ProcessInfo.processInfo.processorCount)),
            memoryBytes: sysctlInteger("hw.memsize") ?? Int64(ProcessInfo.processInfo.physicalMemory),
            volumeBytes: space?.total ?? 0,
            freeBytes: space?.free ?? 0,
            imagesInstalled: imagesInstalled,
            providerRunning: providerRunning(),
            network: await network(),
            power: power(),
            sleepMinutes: sleepMinutes(),
            desktopSession: ownsConsole())
    }

    /// The console (the logged-in desktop) belongs to this user, as the
    /// add-on's installer requires.
    static func ownsConsole() -> Bool {
        var console = stat()
        return stat("/dev/console", &console) == 0 && console.st_uid == getuid()
    }

    /// The inference provider runs, or its add-on socket exists (the add-on
    /// keeps a quarter of the memory for it on the same evidence).
    static func providerRunning() -> Bool {
        if let state = DaemonStateFile.read(), daemonProcessAlive(pid: state.pid) { return true }
        return FileManager.default.fileExists(atPath: AddonHoldPaths.production().socket.path)
    }

    /// Total and unprivileged-free (`f_bavail`) bytes of the volume holding
    /// `url`, or of its nearest existing parent.
    static func volumeSpace(containing url: URL) -> (total: Int64, free: Int64)? {
        var probe = url.standardizedFileURL
        while !FileManager.default.fileExists(atPath: probe.path), probe.path != "/" {
            probe = probe.deletingLastPathComponent()
        }
        var info = statfs()
        guard statfs(probe.path, &info) == 0 else { return nil }
        func bytes(_ blocks: UInt64) -> Int64 {
            let (product, overflow) = blocks.multipliedReportingOverflow(by: UInt64(info.f_bsize))
            return overflow ? .max : Int64(clamping: product)
        }
        return (bytes(UInt64(info.f_blocks)), bytes(UInt64(info.f_bavail)))
    }

    /// The primary path's interface, waiting at most `timeout` for it.
    static func network(timeout: TimeInterval = 1) async -> SandboxHostFacts.Network {
        let monitor = NWPathMonitor()
        let answer = FirstAnswer<SandboxHostFacts.Network>()
        return await withCheckedContinuation { continuation in
            answer.attach(continuation) { monitor.cancel() }
            monitor.pathUpdateHandler = { path in answer.resolve(classify(path)) }
            monitor.start(queue: DispatchQueue(label: "dev.darkbloom.sandbox.network"))
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { answer.resolve(.unknown) }
        }
    }

    static func classify(_ path: NWPath) -> SandboxHostFacts.Network {
        guard path.status == .satisfied else { return .offline }
        if path.usesInterfaceType(.wiredEthernet) { return .ethernet }
        if path.usesInterfaceType(.wifi) { return .wifi }
        return .other
    }

    /// A Mac without an internal battery runs from its power adapter.
    static func power() -> SandboxHostFacts.Power {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return .unknown }
        let sources = (IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]) ?? []
        let hasBattery = sources.contains { source in
            let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any]
            return description?[kIOPSTypeKey] as? String == kIOPSInternalBatteryType
        }
        guard hasBattery else { return .noBattery }
        let providing = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?
        return providing == kIOPSBatteryPowerValue ? .battery : .pluggedIn
    }

    /// System sleep on the power adapter, in minutes (0: never).
    static func sleepMinutes(runner: SecurityCommandRunner = .bounded(timeout: 2)) -> Int? {
        if let settings = try? runner.run("/usr/bin/pmset", ["-g"]), settings.terminationStatus == 0,
           sleepDisabled(settings.stdout) {
            return 0
        }
        guard let custom = try? runner.run("/usr/bin/pmset", ["-g", "custom"]), custom.terminationStatus == 0 else {
            return nil
        }
        return powerAdapterSleepMinutes(custom.stdout)
    }

    /// `SleepDisabled 1` in `pmset -g` overrides every sleep timer.
    static func sleepDisabled(_ output: String) -> Bool {
        output.split(separator: "\n").contains { line in
            let fields = line.split(whereSeparator: \.isWhitespace)
            return fields.count >= 2 && fields[0] == "SleepDisabled" && fields[1] == "1"
        }
    }

    /// The `sleep` value under `AC Power:` in `pmset -g custom`.
    static func powerAdapterSleepMinutes(_ output: String) -> Int? {
        var inPowerAdapterSection = false
        for raw in output.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasSuffix("Power:") {
                inPowerAdapterSection = line == "AC Power:"
                continue
            }
            let fields = line.split(whereSeparator: \.isWhitespace)
            if inPowerAdapterSection, fields.count >= 2, fields[0] == "sleep", let minutes = Int(fields[1]) {
                return minutes
            }
        }
        return nil
    }

    static func sysctlInteger(_ name: String) -> Int64? {
        var value: Int64 = 0
        var size = MemoryLayout<Int64>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        // Some keys are 32-bit: only the low `size` bytes were written.
        return size == MemoryLayout<Int32>.size ? Int64(Int32(truncatingIfNeeded: value)) : value
    }

    static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        let text = String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self).trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : text
    }
}

/// Resumes a continuation with the first answer only; later ones are dropped.
final class FirstAnswer<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Never>?
    private var cleanup: (@Sendable () -> Void)?

    func attach(_ continuation: CheckedContinuation<Value, Never>, cleanup: @escaping @Sendable () -> Void) {
        lock.withLock {
            self.continuation = continuation
            self.cleanup = cleanup
        }
    }

    func resolve(_ value: Value) {
        let (pending, cleanup) = lock.withLock {
            defer { continuation = nil; self.cleanup = nil }
            return (continuation, self.cleanup)
        }
        cleanup?()
        pending?.resume(returning: value)
    }
}
