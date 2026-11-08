import Foundation

/// Where a tool set up for Darkbloom sends its requests, as its config says now.
struct ToolPointer: Equatable, Sendable {
    var baseURL: String?
    var keyFile: URL?
}

/// The tools set up for Darkbloom that point elsewhere than this Mac's local API. Skeleton: none is ever named.
enum ToolAddress {
    static func notice(baseURL: String, keyFile: URL?, environment: ToolIntegrationEnvironment = .current,
                       provider: IntegrationProvider = .current) -> String? {
        nil
    }
}
