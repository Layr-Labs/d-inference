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

/// Whether this Mac can host sandboxes and how many jobs it can run at once.
///
/// The slot rules are the add-on installer's own (its `SlotSizing`), so this
/// estimate matches the slots the installer then chooses: the owner keeps a
/// quarter of the cores (at least 2) and of the memory (at least 8 GiB), a
/// running inference provider keeps another quarter of the memory, a Linux
/// slot takes 4 cores and 16 GiB and a macOS slot 8 cores and 16 GiB, handed
/// out Linux, macOS, Linux, macOS, then Linux only. Disk: a free-space floor
/// of a tenth of the volume (50 to 100 GiB) stays free, the images need
/// 50 GiB above it and each Linux slot a 30 GiB scratch disk.
struct SandboxEligibility: Equatable, Sendable {
    enum Limit: Equatable, Sendable { case cores, memory, disk, maximum }

    struct Check: Equatable, Sendable {
        let level: DiagnosticLevel
        let name: String
        let detail: String
        var fix: String?
    }

    static let gib: Int64 = 1 << 30
    static let minimumMacOSMajor = 27
    static let linuxCores = 4
    static let macOSCores = 8
    static let slotMemory: Int64 = 16 << 30
    /// The most requested macOS runner size.
    static let largeMacOSCores = 12
    static let largeMacOSMemory: Int64 = 32 << 30
    static let imageBytes: Int64 = 50 << 30
    static let linuxScratchBytes: Int64 = 30 << 30
    static let maximumLinuxSlots = 16
    /// macOS runs at most two macOS VMs at once, the owner's own included.
    static let maximumMacOSSlots = 2

    static func freeSpaceFloor(volumeBytes: Int64) -> Int64 {
        max(50 << 30, min(volumeBytes / 10, 100 << 30))
    }

    let facts: SandboxHostFacts
    let keptCores: Int
    let keptMemory: Int64
    let providerMemory: Int64
    /// Cores and memory left for jobs.
    let jobCores: Int
    let jobMemory: Int64
    let diskFloor: Int64
    let imageSpace: Int64
    /// Free space above the floor once the images are in; negative when short.
    let diskForJobs: Int64
    let linuxSlots: Int
    let macOSSlots: Int
    let linuxLimit: Limit
    let macOSLimit: Limit
    /// A 12-core, 32 GB macOS job fits in what is left for jobs.
    let largeMacOSFits: Bool

    init(_ facts: SandboxHostFacts) {
        self.facts = facts
        keptCores = max(2, facts.cores / 4)
        keptMemory = max(8 * Self.gib, facts.memoryBytes / 4)
        providerMemory = facts.providerRunning ? facts.memoryBytes / 4 : 0
        jobCores = max(0, facts.cores - keptCores)
        jobMemory = max(0, facts.memoryBytes - keptMemory - providerMemory)
        diskFloor = Self.freeSpaceFloor(volumeBytes: facts.volumeBytes)
        imageSpace = facts.imagesInstalled ? 0 : Self.imageBytes
        diskForJobs = facts.freeBytes - diskFloor - imageSpace
        let linuxByDisk = diskForJobs < 0 ? 0 : min(Self.maximumLinuxSlots, Int(diskForJobs / Self.linuxScratchBytes))
        let macOSByDisk = diskForJobs >= 0 ? Self.maximumMacOSSlots : 0
        var (cores, memory, linux, macOS) = (jobCores, jobMemory, 0, 0)
        var added = true
        while added {
            added = false
            if linux < linuxByDisk, cores >= Self.linuxCores, memory >= Self.slotMemory {
                (linux, cores, memory, added) = (linux + 1, cores - Self.linuxCores, memory - Self.slotMemory, true)
            }
            if macOS < macOSByDisk, cores >= Self.macOSCores, memory >= Self.slotMemory {
                (macOS, cores, memory, added) = (macOS + 1, cores - Self.macOSCores, memory - Self.slotMemory, true)
            }
        }
        func limit(_ count: Int, byDisk: Int, maximum: Int, needs: Int) -> Limit {
            if count == maximum { return .maximum }
            if count == byDisk { return .disk }
            return cores < needs ? .cores : .memory
        }
        linuxSlots = linux
        macOSSlots = macOS
        linuxLimit = limit(linux, byDisk: linuxByDisk, maximum: Self.maximumLinuxSlots, needs: Self.linuxCores)
        macOSLimit = limit(macOS, byDisk: macOSByDisk, maximum: Self.maximumMacOSSlots, needs: Self.macOSCores)
        largeMacOSFits = macOSByDisk > 0 && jobCores >= Self.largeMacOSCores && jobMemory >= Self.largeMacOSMemory
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

    var eligible: Bool { refusal == nil && linuxSlots + macOSSlots > 0 }

    /// Why no job fits, when none does.
    var shortfall: String? {
        guard refusal == nil, linuxSlots + macOSSlots == 0 else { return nil }
        let kept = "the \(gb(keptMemory)) GB kept for you"
            + (providerMemory > 0 ? " and the \(gb(providerMemory)) GB kept for inference" : "")
        if jobCores < Self.linuxCores {
            return "each job needs \(Self.linuxCores) cores besides the \(keptCores) kept for you; "
                + "this Mac has \(jobCores) left"
        }
        if jobMemory < Self.slotMemory {
            return "each job needs \(gb(Self.slotMemory)) GB of memory besides \(kept); this Mac has \(gb(jobMemory)) GB left"
        }
        // Only disk is short: say how much to free for what cores and memory allow.
        var unlimited = facts
        unlimited.freeBytes = Int64.max / 4
        let potential = SandboxEligibility(unlimited)
        let needed = diskFloor + imageSpace + Int64(potential.linuxSlots) * Self.linuxScratchBytes - facts.freeBytes
        return "free up \(gibUp(needed)) GiB of disk, then this Mac can run "
            + Self.jobsSummary(linux: potential.linuxSlots, macOS: potential.macOSSlots) + " at a time. "
            + "\(gibDown(diskFloor)) GiB stays free for you, the VM images need \(gibDown(imageSpace)) GiB "
            + "and each Linux job \(gibDown(Self.linuxScratchBytes)) GiB"
    }

    /// `1 Linux job and 2 macOS jobs`.
    static func jobsSummary(linux: Int, macOS: Int) -> String {
        [(linux, "Linux"), (macOS, "macOS")].filter { $0.0 > 0 }
            .map { "\($0.0) \($0.1) job\($0.0 == 1 ? "" : "s")" }.joined(separator: " and ")
    }

    /// One line per measured fact, in the `doctor` style.
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
        checks.append(Check(level: jobCores >= Self.linuxCores ? .pass : .fail, name: "CPU",
                            detail: "\(facts.cores) cores; you keep \(keptCores)"))
        let inference = providerMemory > 0 ? ", inference keeps \(gb(providerMemory)) GB" : ""
        checks.append(Check(level: jobMemory >= Self.slotMemory ? .pass : .fail, name: "Memory",
                            detail: "\(gb(facts.memoryBytes)) GB; you keep \(gb(keptMemory)) GB\(inference)"))
        let images = facts.imagesInstalled
            ? "the VM images are installed" : "the VM images take \(gibDown(imageSpace)) GiB"
        checks.append(Check(level: diskForJobs >= 0 ? .pass : .fail, name: "Disk",
                            detail: "\(gibDown(facts.freeBytes)) GiB free; \(gibDown(diskFloor)) GiB stays free "
                                + "for you, \(images), each Linux job \(gibDown(Self.linuxScratchBytes)) GiB"))
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

    /// The verdict and what this Mac can run at a time. `requested` slot
    /// counts replace the estimate for that platform.
    func verdict(linuxRequested: Int? = nil, macOSRequested: Int? = nil) -> [String] {
        if let refusal { return ["Not eligible: \(refusal)"] }
        if let shortfall { return ["Not eligible: \(shortfall)."] }
        let (linux, macOS) = slots(linuxRequested: linuxRequested, macOSRequested: macOSRequested)
        var lines = ["Eligible. At a time, this Mac can run:"]
        lines.append("  " + slotLine("Linux", estimate: linuxSlots, requested: linuxRequested, limit: linuxLimit))
        lines.append("  " + slotLine("macOS", estimate: macOSSlots, requested: macOSRequested, limit: macOSLimit))
        if !fits(linux: linux, macOS: macOS) {
            lines.append("  Those counts need more cores, memory or disk than this Mac has left for jobs; "
                + "jobs may run slowly.")
        }
        if macOS > 0 {
            lines.append(largeMacOSFits
                ? "  The most requested macOS size, 12 cores and 32 GB, fits."
                : "  The most requested macOS size, 12 cores and 32 GB, does not fit: it needs a Mac with at "
                    + "least 16 cores and about 64 GB.")
        }
        if macOS == Self.maximumMacOSSlots {
            lines.append("  macOS runs at most 2 macOS VMs at once, yours included; "
                + "`--macos-slots 1` keeps one for you.")
        }
        return lines
    }

    private func slotLine(_ name: String, estimate: Int, requested: Int?, limit: Limit) -> String {
        let jobs = { (count: Int) in
            count == 0 ? "no \(name) jobs" : count == 1 ? "1 \(name) job" : "\(count) \(name) jobs"
        }
        if let requested, requested != estimate { return jobs(requested) + " (your choice)" }
        let reason: String
        switch limit {
        case .cores: reason = "limited by cores"
        case .memory: reason = "limited by memory"
        case .disk: reason = "limited by free disk"
        case .maximum: reason = name == "macOS" ? "the most macOS allows" : "the add-on's maximum"
        }
        return "\(jobs(estimate)) (\(reason))"
    }

    private func gb(_ bytes: Int64) -> Int64 { bytes / Self.gib }
    private func gibDown(_ bytes: Int64) -> Int64 { max(0, bytes) / Self.gib }
    private func gibUp(_ bytes: Int64) -> Int64 { (max(0, bytes) + Self.gib - 1) / Self.gib }

    /// The effective slot counts after the owner's choices.
    func slots(linuxRequested: Int?, macOSRequested: Int?) -> (linux: Int, macOS: Int) {
        (linuxRequested ?? linuxSlots, macOSRequested ?? macOSSlots)
    }

    /// These counts fit in the cores, memory and disk left for jobs.
    func fits(linux: Int, macOS: Int) -> Bool {
        linux * Self.linuxCores + macOS * Self.macOSCores <= jobCores
            && Int64(linux + macOS) * Self.slotMemory <= jobMemory
            && Int64(linux) * Self.linuxScratchBytes <= diskForJobs
    }
}
