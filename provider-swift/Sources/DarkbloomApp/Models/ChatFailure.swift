import Foundation

struct ChatFailure: Error, Equatable, Sendable {
    enum Recovery: Equatable, Sendable {
        case localAPI
        case models
    }

    var title: String
    var detail: String
    var recovery: Recovery? = nil

    static func from(_ error: LocalEndpointError) -> ChatFailure {
        switch error {
        case .invalidEndpoint:
            ChatFailure(
                title: "The local endpoint address is invalid",
                detail: "Open Local API to check the endpoint, then check the connection again.",
                recovery: .localAPI
            )
        case .unreachable:
            ChatFailure(
                title: "The local endpoint did not respond",
                detail: "Open Local API to check that local serving is running, then try again. Your conversation is still here.",
                recovery: .localAPI
            )
        case .httpError(let status, _):
            httpFailure(status: status)
        case .prematureEndOfStream:
            ChatFailure(
                title: "The response ended early",
                detail: "The local endpoint closed the response before it finished. Any partial response is kept. Try this message again."
            )
        }
    }

    // Do not display raw server details, which may contain prompt content or
    // credentials. The status is enough to choose a useful recovery action.
    private static func httpFailure(status: Int) -> ChatFailure {
        switch status {
        case 401, 403:
            ChatFailure(
                title: "Local API access was denied (HTTP \(status))",
                detail: "Open Local API to check the connection and credentials, then try again.",
                recovery: .localAPI
            )
        case 404:
            ChatFailure(
                title: "The model or chat endpoint is unavailable (HTTP 404)",
                detail: "Check the available models and the Local API setup, then try again.",
                recovery: .models
            )
        case 429, 503:
            ChatFailure(
                title: "The local model is busy (HTTP \(status))",
                detail: "Wait for capacity, then try this message again. Any partial response is kept."
            )
        default:
            ChatFailure(
                title: "The local endpoint returned HTTP \(status)",
                detail: "Try the message again, or open Local API to check the endpoint.",
                recovery: .localAPI
            )
        }
    }

    static let noDiscovery = ChatFailure(
        title: "Local chat is not connected",
        detail: "Open Local API to set up local serving. You can write a message here while you get ready.",
        recovery: .localAPI
    )

    static let untrustedDiscovery = ChatFailure(
        title: "The local endpoint record is stale",
        detail: "Open Local API and reconnect local serving before sending. Your draft and conversation are kept.",
        recovery: .localAPI
    )

    static let noModels = ChatFailure(
        title: "No models are available for chat",
        detail: "Open Models to review your local models, then configure one in Local API and check again.",
        recovery: .models
    )

    static let selectedModelUnavailable = ChatFailure(
        title: "The selected model is unavailable",
        detail: "Check the connection and choose an available model, then try again. Your selected model has not been changed.",
        recovery: .models
    )
}
