import DarkbloomFanCore
import DarkbloomFanProtocol
import DarkbloomFanService
import Foundation

#if canImport(Darwin)
import Darwin
#endif

@testable import darkbloom

/// In-memory AppleSMC with fan, Ftst and GPU sensor keys.
final class FanTestSMC: SMCBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [SMCKey: (info: SMCKeyInfo, bytes: [UInt8])] = [:]
    private var writeFailures: [SMCKey: Int] = [:]
    private var ignoredWrites: Set<SMCKey> = []
    private var recordedWrites: [SMCKey] = []

    /// A Mac with `fanCount` fans in Auto, Ftst clear, and every M4 GPU
    /// sensor at 50 C. Use brand string `FanServiceFixture.brand`.
    init(fanCount: Int = 2, includeFtst: Bool = true, gpuCelsius: Double = 50) {
        setUI8("FNum", UInt8(fanCount))
        for index in 0..<fanCount {
            setFloat(key("F\(index)Ac"), 1_500)
            setFloat(key("F\(index)Mn"), 1_200)
            setFloat(key("F\(index)Mx"), 5_000)
            setFloat(key("F\(index)Tg"), 1_400)
            setUI8(key("F\(index)Md"), 0)
        }
        if includeFtst {
            setUI8("Ftst", 0)
        }
        for sensor in GPUTemperatureCatalog.keys(for: .m4) {
            setFloat(sensor, gpuCelsius)
        }
    }

    func key(_ raw: String) -> SMCKey {
        try! SMCKey(raw)
    }

    func setUI8(_ key: SMCKey, _ value: UInt8) {
        lock.withLock {
            entries[key] = (SMCKeyInfo(dataSize: 1, dataType: try! SMCDataType("ui8 ")), [value])
        }
    }

    func setFloat(_ key: SMCKey, _ value: Double) {
        lock.withLock {
            entries[key] = (
                SMCKeyInfo(dataSize: 4, dataType: try! SMCDataType("flt ")),
                try! SMCValue.float32Bytes(value, key: key)
            )
        }
    }

    /// The next `count` writes to `key` fail.
    func failWrites(to key: SMCKey, count: Int = .max) {
        lock.withLock { writeFailures[key] = count }
    }

    /// Writes to `key` succeed but do not change the value.
    func ignoreWrites(to key: SMCKey) {
        _ = lock.withLock { ignoredWrites.insert(key) }
    }

    var writes: [SMCKey] {
        lock.withLock { recordedWrites }
    }

    func uint8(_ raw: String) throws -> UInt8 {
        try read(key(raw)).uint8()
    }

    func keyInfo(for key: SMCKey) throws -> SMCKeyInfo {
        try lock.withLock {
            guard let entry = entries[key] else { throw SMCError.keyNotFound(key) }
            return entry.info
        }
    }

    func read(_ key: SMCKey) throws -> SMCValue {
        let entry = try lock.withLock {
            guard let found = entries[key] else { throw SMCError.keyNotFound(key) }
            return found
        }
        return try SMCValue(key: key, info: entry.info, bytes: entry.bytes)
    }

    func write(_ key: SMCKey, bytes: [UInt8]) throws {
        try lock.withLock {
            recordedWrites.append(key)
            guard entries[key] != nil else { throw SMCError.keyNotFound(key) }
            if let remaining = writeFailures[key], remaining > 0 {
                writeFailures[key] = remaining - 1
                throw SMCError.injectedFailure("write \(key) rejected")
            }
            if ignoredWrites.contains(key) { return }
            entries[key]?.bytes = bytes
        }
    }
}

/// Scripted `launchctl` and `codesign`. It keeps a loaded flag like launchd
/// and records every call. No real process runs.
final class FanTestLaunchd: @unchecked Sendable {
    private let lock = NSLock()
    private var queued: [String: [FanProcessResult]] = [:]
    private var hooks: [String: () -> Void] = [:]
    private var recordedCalls: [(executable: String, arguments: [String], timeout: TimeInterval)] = []
    private var isLoaded: Bool
    private var enabledLabel: Bool?
    /// When false, `bootstrap` succeeds but the job does not stay loaded.
    var bootstrapLoads = true

    init(loaded: Bool = false) {
        self.isLoaded = loaded
    }

    var loaded: Bool { lock.withLock { isLoaded } }
    var labelEnabled: Bool? { lock.withLock { enabledLabel } }

    /// The next calls of `verb` return `results` in order and change no state.
    /// The verb is the launchctl subcommand, or "codesign".
    func queue(_ verb: String, _ results: FanProcessResult...) {
        lock.withLock { queued[verb, default: []].append(contentsOf: results) }
    }

    /// Runs after each default (not queued) call of `verb`.
    func onCall(_ verb: String, _ hook: @escaping () -> Void) {
        lock.withLock { hooks[verb] = hook }
    }

    var calls: [(executable: String, arguments: [String], timeout: TimeInterval)] {
        lock.withLock { recordedCalls }
    }

    /// launchctl subcommands in call order.
    var launchctlVerbs: [String] {
        calls.filter { $0.executable == "/bin/launchctl" }.compactMap { $0.arguments.first }
    }

    var codesignCalls: [[String]] {
        calls.filter { $0.executable == "/usr/bin/codesign" }.map { $0.arguments }
    }

    func run(_ executable: String, _ arguments: [String], _ timeout: TimeInterval) -> FanProcessResult {
        let verb = executable == "/usr/bin/codesign" ? "codesign" : (arguments.first ?? "")
        let (result, hook): (FanProcessResult, (() -> Void)?) = lock.withLock {
            recordedCalls.append((executable, arguments, timeout))
            if var pending = queued[verb], !pending.isEmpty {
                let next = pending.removeFirst()
                queued[verb] = pending
                return (next, nil)
            }
            let ok = FanProcessResult(status: 0, output: "")
            switch verb {
            case "print":
                return (isLoaded ? ok : FanProcessResult(status: 113, output: "Could not find service"), hooks[verb])
            case "bootout":
                isLoaded = false
            case "bootstrap":
                isLoaded = bootstrapLoads
            case "enable":
                enabledLabel = true
            case "disable":
                enabledLabel = false
            default:
                break
            }
            return (ok, hooks[verb])
        }
        hook?()
        return result
    }
}

/// Fake helper XPC answers.
final class FanTestHelper: @unchecked Sendable {
    private let lock = NSLock()
    private var statusReply: FanServiceStatus?
    private var restoreCount = 0
    private var statusCount = 0

    func answer(_ status: FanServiceStatus?) {
        lock.withLock { statusReply = status }
    }

    var restoreRequests: Int { lock.withLock { restoreCount } }
    var statusRequests: Int { lock.withLock { statusCount } }

    func status() throws -> FanServiceStatus {
        try lock.withLock {
            statusCount += 1
            guard let reply = statusReply else {
                throw FanHelperClientError.unavailable("test helper is not running")
            }
            return reply
        }
    }

    func restoreAutomatic() throws -> FanIPCReply {
        lock.withLock { restoreCount += 1 }
        return FanIPCReply(ok: true)
    }
}

/// A temp install root with fake launchd, SMC, helper and a signed-looking
/// Darkbloom.app. Call `remove()` in a defer.
struct FanServiceFixture {
    static let brand = "Apple M4 Pro"
    static let capabilityMarker = "darkbloom-fan-helper-v1"

    let root: URL
    let paths: FanServicePaths
    let app: URL
    let executable: URL
    let bundledHelper: URL
    let launchd: FanTestLaunchd
    let smc: FanTestSMC
    let helper: FanTestHelper
    let uid: UInt32

    init(smc: FanTestSMC = FanTestSMC(), loaded: Bool = false) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("fan-service-\(UUID().uuidString)")
        let system = root.appendingPathComponent("Library")
        paths = FanServicePaths(
            helper: system.appendingPathComponent("PrivilegedHelperTools/io.darkbloom.fan-helper"),
            launchDaemonPlist: system.appendingPathComponent("LaunchDaemons/io.darkbloom.fan.plist"),
            configuration: system.appendingPathComponent("Application Support/Darkbloom/fan-policy.json"),
            sessionJournal: system.appendingPathComponent("Application Support/Darkbloom/fan-session.json")
        )
        app = root.appendingPathComponent("Darkbloom.app")
        executable = app.appendingPathComponent("Contents/MacOS/darkbloom")
        bundledHelper = app.appendingPathComponent("Contents/Helpers/darkbloom-fan-helper")
        launchd = FanTestLaunchd(loaded: loaded)
        self.smc = smc
        helper = FanTestHelper()
        uid = UInt32(getuid())

        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.createDirectory(
            at: bundledHelper.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("binary \(Self.capabilityMarker) end".utf8).write(to: executable)
        try Data("helper binary bytes".utf8).write(to: bundledHelper)
        try setPermissions(0o755, bundledHelper)
        let marker = app.appendingPathComponent(
            "Contents/Resources/darkbloom-runtime-capabilities/fan-helper-v1")
        try fileManager.createDirectory(
            at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("1\n".utf8).write(to: marker)
    }

    var marker: URL {
        app.appendingPathComponent("Contents/Resources/darkbloom-runtime-capabilities/fan-helper-v1")
    }

    func host(
        effectiveUserID: uid_t = 0,
        executableURL: URL? = nil,
        smcAvailable: Bool = true
    ) -> FanServiceHost {
        let launchd = self.launchd
        let smc = self.smc
        let helper = self.helper
        let executable = executableURL ?? self.executable
        return FanServiceHost(
            effectiveUserID: { effectiveUserID },
            runProcess: { launchd.run($0, $1, $2) },
            makeSMCBackend: {
                guard smcAvailable else { throw SMCError.serviceNotFound }
                return smc
            },
            brandString: Self.brand,
            helperStatus: { try helper.status() },
            helperRestoreAutomatic: { try helper.restoreAutomatic() },
            currentExecutableURL: { executable },
            requiresRootOwnership: false,
            retryDelay: 0
        )
    }

    func manager(
        sudoUID: String? = nil,
        host: FanServiceHost? = nil
    ) -> FanServiceManager {
        var environment: [String: String] = [:]
        environment["SUDO_UID"] = sudoUID ?? String(uid)
        return FanServiceManager(
            paths: paths,
            environment: environment,
            host: host ?? self.host()
        )
    }

    func manager(environment: [String: String]) -> FanServiceManager {
        FanServiceManager(paths: paths, environment: environment, host: host())
    }

    /// A helper status that matches an install for this fixture's user.
    func matchingStatus(enabled: Bool = true) -> FanServiceStatus {
        FanServiceStatus(
            enabled: enabled,
            configuredUID: uid,
            providerActive: false,
            mode: .waitingForProvider,
            chip: "M4",
            gpuSensorKeys: ["Tg0G"],
            gpuTemperatureC: 50,
            triggerTemperatureC: 50,
            releaseTemperatureC: 45,
            speedPercent: 70,
            fans: [],
            lastError: nil
        )
    }

    func writeConfiguration(_ configuration: FanServiceConfiguration) throws {
        try FanDurableFile.writeJSON(
            configuration, to: paths.configuration, permissions: 0o600, owner: nil)
    }

    func readConfiguration() throws -> FanServiceConfiguration {
        try FanDurableFile.readJSON(
            FanServiceConfiguration.self, from: paths.configuration, requireRootOwnership: false)
    }

    func writeJournal(fanIndices: [Int], ownsFtst: Bool = false) throws {
        try FanDurableFile.writeJSON(
            FanSessionJournal(fanIndices: fanIndices, ownsFtst: ownsFtst),
            to: paths.sessionJournal, permissions: 0o600, owner: nil)
    }

    var journalExists: Bool {
        FileManager.default.fileExists(atPath: paths.sessionJournal.path)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

func setPermissions(_ mode: Int, _ url: URL) throws {
    try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
}

func filePermissions(_ url: URL) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
}

func fanPolicy(speed: Double = 70, trigger: Double = 50) throws -> FanPolicyConfiguration {
    try FanPolicyConfiguration(triggerCelsius: trigger, releaseCelsius: trigger - 5, speedPercent: speed)
}

func failed(_ status: Int32 = 5, _ output: String) -> FanProcessResult {
    FanProcessResult(status: status, output: output)
}

/// Returns the `FanServiceManagerError` that `body` throws, or nil.
func fanManagerError(_ body: () throws -> Void) -> FanServiceManagerError? {
    do {
        try body()
        return nil
    } catch let error as FanServiceManagerError {
        return error
    } catch {
        return nil
    }
}
