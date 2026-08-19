import Foundation

protocol SetupStartCLIRunning: Sendable {
    func start(modelID: String) async throws
}

struct ProcessSetupStartCLI: SetupStartCLIRunning {
    let runner: any ProviderCLIRunning
    let timeout: Duration

    init(
        runner: any ProviderCLIRunning = ProcessProviderCLIRunner(),
        timeout: Duration = .seconds(600)
    ) {
        self.runner = runner
        self.timeout = timeout
    }

    func start(modelID: String) async throws {
        _ = try await runner.run(
            arguments: ["start", "--model", modelID, "--local-endpoint"],
            timeout: timeout
        )
    }
}
