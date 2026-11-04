import ProviderCore

/// A line a command's helper prints while the command may show its live line (`DarkbloomCommandLook`): said round the
/// live line when one shows, otherwise exactly `print(line)`.
func sayLine(_ line: String) {
    DarkbloomCommandLook.say(line) { print($0) }
}

extension DarkbloomCommandLook {
    /// The `say` a command hands its helpers when it holds the look: exactly `plain` (its own print), round this look's
    /// live line while one shows.
    func saying(_ plain: @escaping ClusterPairCommands.Say) -> ClusterPairCommands.Say {
        { [self] line in say(line, plain: plain) }
    }
}
