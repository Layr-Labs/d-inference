import Foundation
import Observation

@MainActor
@Observable
final class LocalAPIStore {
    private(set) var state: LocalAPIState
    private(set) var isAPIKeyRevealed = false
    private(set) var lastCopiedItem: LocalAPICopyItem?
    var selectedExample: LocalAPICodeExample = .curl

    init(fixture: LocalAPIFixture = .active) {
        state = LocalAPIFixtures.make(fixture)
    }

    var endpoint: LocalAPIEndpointSnapshot? {
        guard case .running(let endpoint) = state else { return nil }
        return endpoint
    }

    func setAPIKeyRevealed(_ revealed: Bool) {
        isAPIKeyRevealed = revealed && endpoint?.requiresAuthentication == true
    }

    func hideAPIKey() {
        isAPIKeyRevealed = false
    }

    func text(for item: LocalAPICopyItem) -> String? {
        switch item {
        case .command(let mode):
            return mode.startCommand
        case .baseURL, .apiKey, .code:
            break
        }

        guard let endpoint else { return nil }
        switch item {
        case .baseURL:
            return endpoint.baseURL.absoluteString
        case .apiKey:
            return endpoint.apiKey
        case .code(let example):
            return code(example, endpoint: endpoint)
        case .command:
            return nil
        }
    }

    func markCopied(_ item: LocalAPICopyItem) {
        lastCopiedItem = item
    }

    func clearCopyConfirmation() {
        lastCopiedItem = nil
    }

    /// Deterministic UI-only recovery until LocalEndpoint discovery is injected.
    func retryPreviewDiscovery() {
        guard case .unavailable = state else { return }
        state = LocalAPIFixtures.make(.active)
    }

    /// Deterministic UI-only probe recovery. Live integration must replace this
    /// with an authenticated `/v1/models` request.
    func retryPreviewModelCatalog() {
        guard case .running(var endpoint) = state,
              case .failed = endpoint.modelCatalog
        else { return }
        endpoint.modelCatalog = .available(LocalAPIFixtures.sampleModelIDs)
        state = .running(endpoint)
    }

    /// Deterministic UI-only health recovery. Live integration must replace
    /// this with an HTTP health probe before exposing credentials or examples.
    func retryPreviewHealth() {
        guard case .running(var endpoint) = state,
              endpoint.health == .unreachable
        else {
            retryPreviewDiscovery()
            return
        }
        endpoint.health = .reachable
        state = .running(endpoint)
    }

    private func code(
        _ example: LocalAPICodeExample,
        endpoint: LocalAPIEndpointSnapshot
    ) -> String {
        let modelID = endpoint.availableModelIDs?.first ?? "<model-id>"
        switch example {
        case .curl:
            let authLine = endpoint.requiresAuthentication
                ? "  -H \"Authorization: Bearer $OPENAI_API_KEY\" \\\n"
                : ""
            return """
            curl \(endpoint.baseURL.absoluteString)/chat/completions \\
            \(authLine)  -H 'Content-Type: application/json' \\
              -d '{"model":"\(modelID)","messages":[{"role":"user","content":"Hello from this Mac"}]}'
            """

        case .python:
            let apiKey = endpoint.requiresAuthentication
                ? "os.environ[\"OPENAI_API_KEY\"]"
                : "\"not-needed\""
            return """
            import os
            from openai import OpenAI

            client = OpenAI(
                base_url="\(endpoint.baseURL.absoluteString)",
                api_key=\(apiKey),
            )

            response = client.chat.completions.create(
                model="\(modelID)",
                messages=[{"role": "user", "content": "Hello from this Mac"}],
            )
            print(response.choices[0].message.content)
            """
        }
    }
}
