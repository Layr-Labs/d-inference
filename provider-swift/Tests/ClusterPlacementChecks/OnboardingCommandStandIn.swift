/// The setup and configuration checks compile the configuration without the onboarding screens, where
/// `ClusterOnboardingCommand` lives (`ClusterConfiguration.tensorAssistantServesLocally` names the command with it):
/// production's name, as the screens start from when compiled without the package.
enum ClusterOnboardingCommand {
    static func named(_ text: String) -> String { text }
}
