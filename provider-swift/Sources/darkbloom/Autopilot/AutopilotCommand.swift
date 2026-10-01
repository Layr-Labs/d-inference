import ArgumentParser
import Foundation
import ProviderCore

struct Autopilot: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "autopilot", abstract: "Manage experimental demand-based model residency.",
        discussion: "Enrollment is off by default and is not live activation. The rollout starts in shadow mode: proposed changes are recorded without controlling residency. A later explicit live rollout manages only selected cached builds and preserves files on disk. Missing selected models are downloaded during setup.",
        subcommands: [Status.self, Enable.self, Disable.self, Pause.self, Resume.self, Models.self, Pin.self, Unpin.self],
        defaultSubcommand: Status.self)

}
