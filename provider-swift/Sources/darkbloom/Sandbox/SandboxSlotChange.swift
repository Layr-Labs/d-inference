import Foundation

/// The add-on's plan for an installed Mac against the slots it runs now
/// (`status --json`): what rerunning `setup` offers to apply. The counts are
/// the add-on's; the CLI only compares them.
struct SandboxSlotChange: Equatable, Sendable {
    var installedLinux: Int
    var installedMacOS: Int
    var plannedLinux: Int
    var plannedMacOS: Int

    /// Nil when the status names no slots to compare, the plan fits no job,
    /// or it matches the installed counts.
    init?(installed status: SandboxAddonStatus, plan: SandboxSizingPlan) {
        guard status.linux != nil || status.macOS != nil, plan.canRunJobs else { return nil }
        self.init(installedLinux: status.linux?.total ?? 0, installedMacOS: status.macOS?.total ?? 0,
                  plannedLinux: plan.linux.slots, plannedMacOS: plan.macOS.slots)
        guard installedLinux != plannedLinux || installedMacOS != plannedMacOS else { return nil }
    }

    init(installedLinux: Int, installedMacOS: Int, plannedLinux: Int, plannedMacOS: Int) {
        self.installedLinux = installedLinux
        self.installedMacOS = installedMacOS
        self.plannedLinux = plannedLinux
        self.plannedMacOS = plannedMacOS
    }

    /// Adds slots and removes none: what setup applies without a prompt.
    var onlyAdds: Bool { plannedLinux >= installedLinux && plannedMacOS >= installedMacOS }

    /// The owner's options with the plan's counts, as explicit slot options.
    func applying(to options: SandboxSetupOptions) -> SandboxSetupOptions {
        var options = options
        (options.linuxSlots, options.macOSSlots) = (plannedLinux, plannedMacOS)
        return options
    }

    /// The command that applies it.
    var command: String {
        "\(Sandbox.cli) sandbox setup --linux-slots \(plannedLinux) --macos-slots \(plannedMacOS)"
    }

    var headline: String {
        "This Mac now fits \(plannedLinux) Linux + \(plannedMacOS) macOS "
            + "(installed: \(installedLinux) Linux + \(installedMacOS) macOS)."
    }
}
