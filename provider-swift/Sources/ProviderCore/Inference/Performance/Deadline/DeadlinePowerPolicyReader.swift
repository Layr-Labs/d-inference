import Foundation
import IOKit.ps
import Darwin

enum DeadlinePowerPolicyReader {
    /// Only this background reader launches a process. The public SDK exposes
    /// Low Power state but not the Automatic/High Power preference; use the
    /// same read-only system command as qualification, with bounded lifetime.
    static func readModes() -> [String: Int]? {
        let process = Process()
        let output = Pipe()
        let finished = DispatchSemaphore(value: 0)
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-g", "custom"]
        process.environment = ["LC_ALL": "C"]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { _ in finished.signal() }
        do { try process.run() } catch { return nil }
        guard finished.wait(timeout: .now() + 1) == .success else {
            process.terminate()
            if finished.wait(timeout: .now() + 0.1) != .success { kill(process.processIdentifier, SIGKILL) }
            return nil
        }
        guard process.terminationStatus == 0,
            let data = try? output.fileHandleForReading.read(upToCount: 32 * 1024),
            data.count < 32 * 1024, let text = String(data: data, encoding: .utf8) else { return nil }
        return parseModes(text)
    }

    static func parseModes(_ text: String) -> [String: Int]? {
        var section: String?
        var modes: [String: Int] = [:]
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line == "AC Power:" { section = "ac"; continue }
            if line == "Battery Power:" { section = "battery"; continue }
            let parts = line.split(whereSeparator: { $0.isWhitespace })
            guard parts.first == "powermode" else { continue }
            guard parts.count == 2, let section, let mode = Int(parts[1]),
                (0...2).contains(mode), modes[section] == nil else { return nil }
            modes[section] = mode
        }
        return modes.isEmpty ? nil : modes
    }

    static func activeSource() -> String? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
            let source = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String? else { return nil }
        switch source {
        case kIOPSACPowerValue: return "ac"
        case kIOPSBatteryPowerValue: return "battery"
        default: return nil
        }
    }
}
