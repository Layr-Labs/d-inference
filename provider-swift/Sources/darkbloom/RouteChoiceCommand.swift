import ArgumentParser
import Foundation
import ProviderCore

// Seams for the red tests of `darkbloom route <choice>`, with today's behaviour: `route` has only `key`, so these
// commands are not reachable, and nothing saves `[local] route` but a hand edit or `start --route`.

struct RouteThisMac: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: LocalSettings.Route.thisMac.rawValue)
    @OptionGroup var configOptions: ConfigOptions
}

struct RouteMyMacs: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: LocalSettings.Route.myMacs.rawValue)
    @OptionGroup var configOptions: ConfigOptions
}

struct RouteMyMacsFirst: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: LocalSettings.Route.myMacsFirst.rawValue)
    @OptionGroup var configOptions: ConfigOptions
}

struct RouteChoiceFlow {
    let accountKeySaved: () -> Bool
    let save: (LocalSettings.Route) throws -> Bool
    var liveEndpoint: LocalEndpoint.Info?
    var pairLeader: String?
    let say: (String) -> Void

    func choose(_ route: LocalSettings.Route) -> Int32 { 1 }
}
