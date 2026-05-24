import ArgumentParser

@main
struct DarkbloomPublish: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "darkbloom-publish",
        abstract: "Compute model manifests for the Darkbloom model registry.",
        discussion: """
            Runs on Linux or macOS. Used by the publish-model.sh wrapper on \
            a GCP VM to produce a manifest.json before bytes are uploaded to R2.
            """,
        subcommands: [HashCommand.self]
    )
}
