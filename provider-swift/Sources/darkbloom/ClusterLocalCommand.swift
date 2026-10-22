import Foundation
import ArgumentParser
import ProviderCore

extension Cluster {
    /// `darkbloom cluster local [model]`: the onboarding asked to serve on the leading Mac's local API only. The pair
    /// is set up and planned exactly as with `darkbloom cluster`; no Mac of the cluster contacts a coordinator.
    struct Local: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "local",
            abstract: "Serve the cluster on the leading Mac's local API only, never contacting Darkbloom's coordinator.",
            discussion: """
                The same as `darkbloom cluster` (pairing, model choice, the split across the Macs, model copies), but \
                the cluster serves on the leading Mac's local OpenAI-compatible API only: no registration, public \
                traffic or billing, and no network beyond the cable is needed to serve. The API listens on every \
                network of the leading Mac (LAN or tailnet) unless --bind names an address, and always needs its API \
                key: `darkbloom local` on that Mac shows the address and the key.

                The choice is kept: both Macs serve this way after restarts, until `darkbloom cluster` is used to \
                serve through Darkbloom again (press p there). Run it on a cluster that already serves to switch it.
                """)
        @OptionGroup var configOptions: ConfigOptions
        @Argument(help: "The model to serve, by its id or name as `darkbloom cluster` lists it; without one, the list is shown.")
        var model: String?
        @Option(help: ArgumentHelp("The address the API listens on (default 0.0.0.0: every network of the leading Mac; 127.0.0.1: that Mac only). The API key is always required.",
                                   valueName: "address"))
        var bind: String?
        @Option(name: .customLong("model-dir"), help: ArgumentHelp("Developer: absolute path of the folder holding this Mac's model folders.", visibility: .hidden))
        var modelDir: String?
        @Option(help: ArgumentHelp("Developer: absolute path of this Mac's cluster worker, when it is not the installed one.", visibility: .hidden))
        var worker: String?

        @Flag(name: .customLong("private-mimo-image-qualification"),
              help: ArgumentHelp("Private, unqualified PNG candidate on the already paired control leader; exact MiMo model id required.", visibility: .hidden))
        var privateMiMoImageQualification = false

        @Flag(name: .customLong("private-glm-image-qualification"),
              help: "Select the unqualified GLM PNG candidate on the paired local leader; exact GLM model id required.")
        var privateGLMImageQualification = false

        var onboardingRequest: ClusterOnboardingRequest {
            .init(scope: .localOnly(bind: bind ?? ClusterServingScope.localOnlyDefaultBind), model: model,
                  privateMiMoImageQualification: privateMiMoImageQualification, privateGLMImageQualification: privateGLMImageQualification)
        }

        static let needsTerminalLine = "Run `darkbloom cluster local` in a Terminal window on this Mac."

        func validate() throws {
            if let refusal = onboardingRequest.privateQualificationInputRefusal { throw ValidationError(refusal) }
            for path in [configOptions.config, modelDir, worker].compactMap({ $0 }) {
                guard path.hasPrefix("/"), !path.contains("\0") else { throw ValidationError("`darkbloom cluster local` takes absolute paths.") }
            }
            if let model {
                guard !model.isEmpty, model.utf8.count <= 200, !model.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                    throw ValidationError("Name the model by its id or name as `darkbloom cluster` lists it.")
                }
            }
            if let bind, !ClusterServingScope.isValidBind(bind) {
                throw ValidationError("--bind takes localhost or a numeric IPv4 or IPv6 address (0.0.0.0 = every network of the leading Mac).")
            }
        }

        mutating func run() async throws {
            guard isatty(STDIN_FILENO) == 1, isatty(STDOUT_FILENO) == 1 else {
                print(Self.needsTerminalLine)
                throw ExitCode.failure
            }
            try await Cluster.Setup.runOnboarding(config: configOptions.config, modelDir: modelDir, worker: worker,
                request: onboardingRequest)
        }
    }
}
