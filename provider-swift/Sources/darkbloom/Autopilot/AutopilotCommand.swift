import ArgumentParser
import Foundation
import ProviderCore

struct Autopilot: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "autopilot", abstract: "Manage experimental demand-based model residency.",
        discussion: "Enrollment is off by default and is not live activation. Yes reports already-downloaded network-supported models, then keeps the normal startup model and memory selector. Enrollment itself downloads nothing; once enrolled, Autopilot may download catalog models on your behalf unless you limit or turn that off with `darkbloom autopilot downloads`. Shadow records proposals without changing residency; a later explicit live rollout chooses cached models to improve utilization.",
        subcommands: [Status.self, Enable.self, Disable.self, Pause.self, Resume.self, Models.self, Pin.self, Unpin.self,
                      Downloads.self],
        defaultSubcommand: Status.self)

}
