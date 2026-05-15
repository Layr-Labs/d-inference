import ArgumentParser
import Foundation

let arguments = Array(CommandLine.arguments.dropFirst())
let knownSubcommands = Set(Darkbloom.configuration.subcommands.flatMap { command -> [String] in
    [command._commandName] + command.configuration.aliases
})

if let first = arguments.first,
   !first.hasPrefix("-"),
   first != "help",
   !knownSubcommands.contains(first)
{
    FileHandle.standardError.write(Data("Error: Unknown subcommand \"\(first)\"\n".utf8))
    Foundation.exit(64)
}

do {
    var command = try Darkbloom.parseAsRoot(arguments)
    if var asyncCommand = command as? AsyncParsableCommand {
        try await asyncCommand.run()
    } else {
        try command.run()
    }
} catch {
    Darkbloom.exit(withError: error)
}
