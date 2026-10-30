import Foundation
import ProviderCore

/// What `darkbloom sandbox setup` measures before it installs anything.
struct SandboxHostFacts: Equatable, Sendable {
    enum Network: Equatable, Sendable { case ethernet, wifi, other, offline, unknown }
    enum Power: Equatable, Sendable { case noBattery, pluggedIn, battery, unknown }

    var chip: String
    var appleSilicon: Bool
    var macOSVersion: String
    var macOSMajor: Int
    var cores: Int
    var memoryBytes: Int64
    /// The volume that holds the add-on's root (the home folder's volume).
    var volumeBytes: Int64
    var freeBytes: Int64
    /// The VM images are already on disk (a rerun), so they need no space.
    var imagesInstalled: Bool
    /// The inference provider runs here, so it keeps a quarter of the memory.
    var providerRunning: Bool
    var network: Network
    var power: Power
    /// Minutes before system sleep on the power adapter; 0 is never.
    var sleepMinutes: Int?
    /// This user is logged in at the Mac's desktop, where the add-on runs.
    var desktopSession = true
    var userName = NSUserName()
}

/// Whether this Mac can host sandboxes, from the checks setup makes itself:
/// chip, macOS, desktop session, network, power and sleep. How many jobs it
/// can run at a time is the add-on's own plan (`SandboxSizingPlan`), which
/// setup asks the installer for; `estimatedPlan` is the fallback for an
/// installer without one.
struct SandboxEligibility: Equatable, Sendable {
    struct Check: Equatable, Sendable {
        let level: DiagnosticLevel
        let name: String
        let detail: String
        var fix: String?
    }

    static let gib: Int64 = 1 << 30
    static let minimumMacOSMajor = 27
    static let maximumLinuxSlots = 16
    /// macOS runs at most two macOS VMs at once, the owner's own included.
    static let maximumMacOSSlots = 2
    /// The most requested macOS runner size.
    static let largeMacOSCores = 12
    static let largeMacOSMemory: Int64 = 32 << 30

    let facts: SandboxHostFacts

    init(_ facts: SandboxHostFacts) {
        self.facts = facts
    }

    /// A reason this Mac can never host sandboxes as it is, whatever its size.
    var refusal: String? {
        if !facts.appleSilicon {
            return "Darkbloom Sandbox needs a Mac with Apple silicon (this one has \(facts.chip))."
        }
        if facts.macOSMajor < Self.minimumMacOSMajor {
            return "Darkbloom Sandbox needs macOS \(Self.minimumMacOSMajor) or later; this Mac runs macOS "
                + "\(facts.macOSVersion). Update it in System Settings → General → Software Update first."
        }
        if facts.network == .offline {
            return "This Mac is not connected to the Internet."
        }
        if !facts.desktopSession {
            return "Log in to this Mac's desktop as \(facts.userName) and run setup there: the add-on runs in "
                + "your login session."
        }
        return nil
    }

    /// One line per fact setup checks itself, in the `doctor` style; the
    /// sizing lines come from the plan.
    var checks: [Check] {
        var checks: [Check] = []
        checks.append(facts.appleSilicon
            ? Check(level: .pass, name: "Chip", detail: facts.chip)
            : Check(level: .fail, name: "Chip", detail: "\(facts.chip): Apple silicon is required"))
        checks.append(facts.macOSMajor >= Self.minimumMacOSMajor
            ? Check(level: .pass, name: "macOS", detail: facts.macOSVersion)
            : Check(level: .fail, name: "macOS",
                    detail: "\(facts.macOSVersion): macOS \(Self.minimumMacOSMajor) or later is required",
                    fix: "update in System Settings → General → Software Update"))
        checks.append(facts.desktopSession
            ? Check(level: .pass, name: "Session", detail: "logged in at this Mac's desktop")
            : Check(level: .fail, name: "Session", detail: "not logged in at this Mac's desktop",
                    fix: "log in at the desktop as \(facts.userName); the add-on runs in that session"))
        checks.append(networkCheck)
        checks.append(powerCheck)
        checks.append(sleepCheck)
        return checks
    }

    private var networkCheck: Check {
        switch facts.network {
        case .ethernet: return Check(level: .pass, name: "Network", detail: "Ethernet")
        case .wifi:
            return Check(level: .warn, name: "Network", detail: "Wi-Fi (jobs and VM images download a lot)",
                         fix: "use Ethernet if you can; it is faster and steadier")
        case .other: return Check(level: .info, name: "Network", detail: "connected")
        case .offline:
            return Check(level: .fail, name: "Network", detail: "not connected", fix: "connect this Mac to the Internet")
        case .unknown: return Check(level: .info, name: "Network", detail: "could not tell the connection type")
        }
    }

    private var powerCheck: Check {
        switch facts.power {
        case .noBattery: return Check(level: .pass, name: "Power", detail: "power adapter")
        case .pluggedIn: return Check(level: .pass, name: "Power", detail: "plugged in")
        case .battery:
            return Check(level: .warn, name: "Power", detail: "on battery (a job lost to a flat battery is not paid)",
                         fix: "keep this Mac plugged in")
        case .unknown: return Check(level: .info, name: "Power", detail: "could not read the power source")
        }
    }

    private var sleepCheck: Check {
        guard let minutes = facts.sleepMinutes else {
            return Check(level: .info, name: "Sleep", detail: "could not read the sleep setting")
        }
        guard minutes > 0 else { return Check(level: .pass, name: "Sleep", detail: "off on the power adapter") }
        return Check(level: .warn, name: "Sleep",
                     detail: "after \(minutes) min idle (a sleeping Mac gets no jobs and loses running ones)",
                     fix: "sudo pmset -c sleep 0")
    }

}

// MARK: - Fallback sizing

extension SandboxEligibility {
    static let linuxCores = 4
    static let macOSCores = 8
    static let slotMemory: Int64 = 16 << 30
    static let linuxImagesBytes: Int64 = 4 << 30
    static let macOSImagesBytes: Int64 = 46 << 30
    static let linuxSlotBytes: Int64 = 30 << 30
    static let macOSSlotBytes: Int64 = 40 << 30

    static func freeSpaceFloor(volumeBytes: Int64) -> Int64 {
        max(50 << 30, min(volumeBytes / 10, 100 << 30))
    }

    /// The fallback when the installer reports no plan (before add-on 1.1.1):
    /// the add-on's slot rules as of 1.1.1, computed here. The owner keeps a
    /// quarter of the cores (at least 2) and of the memory (at least 8 GiB), a
    /// running inference provider another quarter of the memory. A Linux slot
    /// takes 4 cores and 16 GiB, a macOS slot 8 cores and 16 GiB, handed out
    /// Linux, macOS, Linux, macOS, then Linux only while cores, memory and the
    /// disk above the floor last. Counts the owner chose replace the estimate.
    func estimatedPlan(linuxRequested: Int? = nil, macOSRequested: Int? = nil) -> SandboxSizingPlan {
        let images = { (bytes: Int64) in facts.imagesInstalled ? 0 : bytes }
        let floor = Self.freeSpaceFloor(volumeBytes: facts.volumeBytes)
        var plan = SandboxSizingPlan(
            linux: .init(slots: 0, imagesBytes: images(Self.linuxImagesBytes), slotBytes: Self.linuxSlotBytes),
            macOS: .init(slots: 0, imagesBytes: images(Self.macOSImagesBytes), slotBytes: Self.macOSSlotBytes),
            freeBytes: facts.freeBytes, floorBytes: floor, cores: facts.cores, coresKept: max(2, facts.cores / 4),
            memoryBytes: facts.memoryBytes, memoryKeptBytes: max(8 * Self.gib, facts.memoryBytes / 4),
            providerMemoryBytes: facts.providerRunning ? facts.memoryBytes / 4 : 0)
        var (cores, memory, disk) = (plan.jobCores, plan.jobMemory, facts.freeBytes - floor)
        func add(_ platform: inout SandboxSizingPlan.Platform, cores needed: Int, maximum: Int) -> Bool {
            let diskNeeded = platform.nextSlotBytes
            guard platform.slots < maximum, cores >= needed, memory >= Self.slotMemory, disk >= diskNeeded else {
                return false
            }
            (cores, memory, disk) = (cores - needed, memory - Self.slotMemory, disk - diskNeeded)
            platform.slots += 1
            return true
        }
        func limit(_ platform: SandboxSizingPlan.Platform, cores needed: Int, maximum: Int) -> String {
            if platform.slots == maximum { return "the maximum" }
            if disk < platform.nextSlotBytes { return "free disk space" }
            return cores < needed ? "cores" : "memory"
        }
        var added = true
        while added {
            let linux = add(&plan.linux, cores: Self.linuxCores, maximum: Self.maximumLinuxSlots)
            let macOS = add(&plan.macOS, cores: Self.macOSCores, maximum: Self.maximumMacOSSlots)
            added = linux || macOS
        }
        plan.linux.limit = limit(plan.linux, cores: Self.linuxCores, maximum: Self.maximumLinuxSlots)
        plan.macOS.limit = limit(plan.macOS, cores: Self.macOSCores, maximum: Self.maximumMacOSSlots)
        if let linuxRequested { (plan.linux.slots, plan.linux.automatic, plan.linux.limit) = (linuxRequested, false, nil) }
        if let macOSRequested { (plan.macOS.slots, plan.macOS.automatic, plan.macOS.limit) = (macOSRequested, false, nil) }
        if !plan.runsJobs { plan.message = Self.noJobReason(plan) }
        return plan
    }

    /// Why the estimate fits no job: cores or memory, else what the disk and
    /// slot lines of the report say.
    private static func noJobReason(_ plan: SandboxSizingPlan) -> String {
        if plan.jobCores < linuxCores {
            return "each job needs \(linuxCores) cores besides the \(plan.coresKept) kept for you; "
                + "this Mac has \(plan.jobCores) left"
        }
        guard plan.jobMemory >= slotMemory else {
            let inference = plan.providerMemoryBytes > 0
                ? " and the \(gb(plan.providerMemoryBytes)) GB kept for inference" : ""
            return "each job needs \(gb(slotMemory)) GB of memory besides the \(gb(plan.memoryKeptBytes)) GB kept "
                + "for you\(inference); this Mac has \(gb(plan.jobMemory)) GB left"
        }
        return "no job fits on this Mac"
    }
}

// MARK: - The plan in the report

extension SandboxSizingPlan {
    /// Cores and memory left for jobs.
    var jobCores: Int { max(0, cores - coresKept) }
    var jobMemory: Int64 { max(0, memoryBytes - memoryKeptBytes - providerMemoryBytes) }
    var runsJobs: Bool { linux.slots + macOS.slots > 0 }

    /// Free disk one job of `platform` needs beyond what is free now, its
    /// images included; 0 when it fits.
    func diskShortfall(_ platform: Platform) -> Int64 {
        max(0, floorBytes + platform.imagesBytes + platform.slotBytes - freeBytes)
    }

    /// The CPU, memory and disk lines, in the `doctor` style. When no job
    /// fits, the lines a limit names fail.
    var checks: [SandboxEligibility.Check] {
        func level(_ resource: String) -> DiagnosticLevel {
            !runsJobs && [linux.limit, macOS.limit].contains(where: { $0?.contains(resource) == true }) ? .fail : .pass
        }
        func disk(_ name: String, _ platform: Platform) -> String {
            let images = platform.imagesBytes > 0 ? "\(gibDown(platform.imagesBytes)) GiB" : "installed"
            return "\(name) images \(images) + \(gibDown(platform.slotBytes)) GiB per \(name) job"
        }
        let inference = providerMemoryBytes > 0 ? ", inference keeps \(gb(providerMemoryBytes)) GB" : ""
        return [
            .init(level: level("core"), name: "CPU", detail: "\(cores) cores; you keep \(coresKept)"),
            .init(level: level("memory"), name: "Memory",
                  detail: "\(gb(memoryBytes)) GB; you keep \(gb(memoryKeptBytes)) GB\(inference)"),
            .init(level: level("disk"), name: "Disk",
                  detail: "\(gibDown(freeBytes)) GiB free; \(gibDown(floorBytes)) GiB stays free for you; "
                      + disk("Linux", linux) + "; " + disk("macOS", macOS)),
        ]
    }

    /// The verdict, then what this Mac can run at a time or what it lacks.
    var verdict: [String] {
        guard runsJobs else { return shortfall }
        var lines = ["Eligible. At a time, this Mac can run:",
                     "  " + Self.slotLine("Linux", linux), "  " + Self.slotLine("macOS", macOS)]
        if macOS.slots > 0 {
            lines.append(jobCores >= SandboxEligibility.largeMacOSCores && jobMemory >= SandboxEligibility.largeMacOSMemory
                ? "  The most requested macOS size, 12 cores and 32 GB, fits."
                : "  The most requested macOS size, 12 cores and 32 GB, does not fit: it needs a Mac with at "
                    + "least 16 cores and about 64 GB.")
        }
        if macOS.slots == SandboxEligibility.maximumMacOSSlots {
            lines.append("  macOS runs at most 2 macOS VMs at once, yours included; "
                + "`--macos-slots 1` keeps one for you.")
        }
        return lines
    }

    /// The plan's message, how much disk to free for one job of each
    /// platform, and whether the owner's counts are why.
    private var shortfall: [String] {
        let reason = message ?? "no job fits on this Mac"
        var lines = ["Not eligible: \(reason)" + (reason.hasSuffix(".") ? "" : ".")]
        let disk = [("Linux", linux), ("macOS", macOS)].compactMap { name, platform -> String? in
            let short = diskShortfall(platform)
            return short > 0 ? "\(gibUp(short)) GiB of disk for one \(name) job" : nil
        }
        if !disk.isEmpty { lines.append("  Free up " + disk.joined(separator: ", or ") + ".") }
        if !linux.automatic || !macOS.automatic {
            lines.append("  That is with the slot counts you chose; change --linux-slots or --macos-slots.")
        }
        return lines
    }

    private static func slotLine(_ name: String, _ platform: Platform) -> String {
        let jobs = platform.slots == 0 ? "no \(name) jobs"
            : "\(platform.slots) \(name) job" + (platform.slots == 1 ? "" : "s")
        guard platform.automatic else { return "\(jobs) (your choice)" }
        return platform.limit.map { "\(jobs) (limited by \($0))" } ?? jobs
    }
}

extension SandboxSizingPlan.Platform {
    /// Disk its next slot takes: the first one brings the images.
    var nextSlotBytes: Int64 { (slots == 0 ? imagesBytes : 0) + slotBytes }
}

private func gb(_ bytes: Int64) -> Int64 { bytes / SandboxEligibility.gib }
private func gibDown(_ bytes: Int64) -> Int64 { max(0, bytes) / SandboxEligibility.gib }
private func gibUp(_ bytes: Int64) -> Int64 { (max(0, bytes) + SandboxEligibility.gib - 1) / SandboxEligibility.gib }
