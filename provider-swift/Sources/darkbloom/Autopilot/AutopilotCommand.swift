import ArgumentParser
import Foundation
import ProviderCore

struct Autopilot: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "autopilot", abstract: "Manage experimental demand-based model residency.",
        discussion: "Enrollment is off by default and is not live activation. Yes reports already-downloaded network-supported models, without another picker or downloads. Saved model, preload and idle preferences are preserved. Shadow records proposals without changing residency; a later explicit live rollout chooses cached models to improve utilization.",
        subcommands: [Status.self, Enable.self, Disable.self, Pause.self, Resume.self, Models.self, Pin.self, Unpin.self],
        defaultSubcommand: Status.self)

}
