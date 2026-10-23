import Darwin
import Foundation

/// Operator guidance for the macOS GPU wired-memory limit while serving
/// GLM-5.3-Flash. Advice only: capacity, admission and KV grants never read it.
///
/// GLM's KV grant is sized from physical memory (`UnifiedMemoryCap`), so at
/// full KV a 256 GB M5 Ultra plans the whole cap, about 247 GB, as GPU memory.
/// Under macOS's default (`iogpu.wired_limit_mb=0`) the GPU may use only the
/// Metal recommended working set, about 222 GiB there, and command buffers past
/// it fail with "Insufficient Memory". The recommendation is the sysctl set the
/// production 256 GB hosts run. Other sizes get no advice: at 512 GB the same
/// derivation would set the user wire limits below the GPU limit, which no host
/// has run.
public enum GLM5NextWiredLimit {
    static let validatedMemoryGiB: UInt64 = 256
    static let launchDaemonLabel = "com.layrlabs.glm53-wired-limits"
    static let launchDaemonPath = "/Library/LaunchDaemons/\(launchDaemonLabel).plist"

    public struct Recommendation: Sendable, Equatable {
        public let memoryGiB: UInt64
        /// `iogpu.wired_limit_mb`: physical memory less 16 GiB, in MiB.
        public let gpuWiredLimitMB: UInt64
        /// `vm.global_user_wire_limit` and `vm.user_wire_limit`: 95% of physical memory.
        public let userWireLimitBytes: UInt64

        public var gpuWiredLimitBytes: UInt64 { gpuWiredLimitMB << 20 }

        /// GPU memory GLM plans at full KV: the provider's default hard cap.
        public var plannedGPUBytes: UInt64 {
            UnifiedMemoryCap.hardCapBytes(
                physicalBytes: memoryGiB << 30, capFraction: UnifiedMemoryCap.defaultCapFraction)
        }

        public func isMet(by limits: Limits) -> Bool {
            limits.gpuLimitBytes >= gpuWiredLimitBytes
                && (limits.globalUserWireLimitBytes ?? 0) >= userWireLimitBytes
                && (limits.userWireLimitBytes ?? 0) >= userWireLimitBytes
        }

        public var sysctlAssignments: [String] {
            [
                "iogpu.wired_limit_mb=\(gpuWiredLimitMB)",
                "vm.global_user_wire_limit=\(userWireLimitBytes)",
                "vm.user_wire_limit=\(userWireLimitBytes)",
            ]
        }

        /// Applies until the next reboot.
        public var sysctlCommand: String {
            "sudo sysctl -w " + sysctlAssignments.joined(separator: " ")
        }

        /// Reapplies `sysctlAssignments` at every boot.
        public var launchDaemonPlist: String {
            let arguments = (["/usr/sbin/sysctl", "-w"] + sysctlAssignments)
                .map { "\t\t<string>\($0)</string>" }
            let log = "/var/log/\(GLM5NextWiredLimit.launchDaemonLabel).log"
            return ([
                #"<?xml version="1.0" encoding="UTF-8"?>"#,
                #"<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">"#,
                #"<plist version="1.0">"#,
                "<dict>",
                "\t<key>Label</key>",
                "\t<string>\(GLM5NextWiredLimit.launchDaemonLabel)</string>",
                "\t<key>ProgramArguments</key>",
                "\t<array>",
            ] + arguments + [
                "\t</array>",
                "\t<key>RunAtLoad</key>",
                "\t<true/>",
                "\t<key>StandardOutPath</key>",
                "\t<string>\(log)</string>",
                "\t<key>StandardErrorPath</key>",
                "\t<string>\(log)</string>",
                "</dict>",
                "</plist>",
            ]).joined(separator: "\n")
        }

        /// Copy-paste lines that install the LaunchDaemon. They are unindented
        /// because the XML declaration must start the file.
        public var launchDaemonInstallCommands: [String] {
            ["sudo tee \(GLM5NextWiredLimit.launchDaemonPath) >/dev/null <<'EOF'", launchDaemonPlist, "EOF",
             "sudo launchctl bootstrap system \(GLM5NextWiredLimit.launchDaemonPath)"]
        }

        /// One line for logs and command output. It carries no request, model
        /// input or error text.
        public func notice(cliName: String) -> String {
            "GLM-5.3-Flash at full KV needs more GPU memory than this Mac's macOS wired-memory "
                + "limits allow (Metal \"Insufficient Memory\"). Fix: \(sysctlCommand), then "
                + "`\(cliName) restart`; `\(cliName) doctor` shows how to keep it after reboot."
        }
    }

    /// The live macOS limits. A nil sysctl could not be read.
    public struct Limits: Sendable, Equatable {
        /// `iogpu.wired_limit_mb`; 0 keeps the macOS default.
        public var gpuWiredLimitMB: UInt64?
        public var globalUserWireLimitBytes: UInt64?
        public var userWireLimitBytes: UInt64?
        /// Metal's recommended working set, the GPU limit while `iogpu.wired_limit_mb` is 0.
        public var metalWorkingSetBytes: UInt64

        public init(
            gpuWiredLimitMB: UInt64?, globalUserWireLimitBytes: UInt64?,
            userWireLimitBytes: UInt64?, metalWorkingSetBytes: UInt64
        ) {
            self.gpuWiredLimitMB = gpuWiredLimitMB
            self.globalUserWireLimitBytes = globalUserWireLimitBytes
            self.userWireLimitBytes = userWireLimitBytes
            self.metalWorkingSetBytes = metalWorkingSetBytes
        }

        public var gpuLimitBytes: UInt64 {
            guard let megabytes = gpuWiredLimitMB, megabytes > 0 else { return metalWorkingSetBytes }
            return megabytes > UInt64.max >> 20 ? .max : megabytes << 20
        }

        public static func live() -> Limits {
            Limits(
                gpuWiredLimitMB: sysctlUnsigned("iogpu.wired_limit_mb"),
                globalUserWireLimitBytes: sysctlUnsigned("vm.global_user_wire_limit"),
                userWireLimitBytes: sysctlUnsigned("vm.user_wire_limit"),
                metalWorkingSetBytes: GPUEnforcement.probeMetal().recommendedMaxWorkingSetSizeBytes)
        }
    }

    /// Nil unless this is an M5-family Mac of the validated memory size.
    public static func recommendation(chipFamily: ChipFamily, memoryGiB: UInt64) -> Recommendation? {
        guard chipFamily == .m5, memoryGiB == validatedMemoryGiB else { return nil }
        let physicalBytes = memoryGiB << 30
        return Recommendation(
            memoryGiB: memoryGiB,
            gpuWiredLimitMB: (physicalBytes - (16 << 30)) >> 20,
            userWireLimitBytes: physicalBytes * 95 / 100)
    }

    /// The recommendation for the Mac running this process: one sysctl, no
    /// system_profiler.
    static func recommendationForThisMac() -> Recommendation? {
        let chipFamily = parseChipIdentity((try? sysctlString("machdep.cpu.brand_string")) ?? "").0
        return recommendation(
            chipFamily: chipFamily, memoryGiB: ProcessInfo.processInfo.physicalMemory >> 30)
    }

    /// The coordinator catalog build or the local qualification download.
    public static func isGLM5Next(modelID: String) -> Bool {
        GLM5NextCoordinatorServing.isManagedModelID(modelID)
    }

    public static func isGLM5Next(_ model: ModelInfo) -> Bool {
        model.modelType == "glm5_next" || isGLM5Next(modelID: model.id)
    }

    /// True for MLX's report of a Metal command buffer that ran out of GPU
    /// memory. The provider's own admission refusals ("Insufficient memory
    /// for …") never match.
    public static func isMetalOutOfMemory(_ text: String) -> Bool {
        text.contains("kIOGPUCommandBufferCallbackErrorOutOfMemory")
            || text.contains("Command buffer execution failed: Insufficient Memory")
    }

    public static func isMetalOutOfMemory(_ error: any Error) -> Bool {
        isMetalOutOfMemory(String(describing: error)) || isMetalOutOfMemory(error.localizedDescription)
    }
}

/// `iogpu.wired_limit_mb` is 32-bit and the wire limits are 64-bit.
private func sysctlUnsigned(_ name: String) -> UInt64? {
    var size = 0
    guard sysctlbyname(name, nil, &size, nil, 0) == 0 else { return nil }
    switch size {
    case MemoryLayout<UInt32>.size:
        var value: UInt32 = 0
        return sysctlbyname(name, &value, &size, nil, 0) == 0 ? UInt64(value) : nil
    case MemoryLayout<UInt64>.size:
        var value: UInt64 = 0
        return sysctlbyname(name, &value, &size, nil, 0) == 0 ? value : nil
    default:
        return nil
    }
}
