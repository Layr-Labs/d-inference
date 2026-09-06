import Foundation
import ProviderCoreFoundation

/// How the live chat store reaches a real endpoint: discovery record →
/// client, current model → request. Every I/O seam is injectable so tests
/// never touch the network or the real `~/.darkbloom`.
struct LiveChatConfiguration: Sendable {
    /// Reads the local-endpoint discovery record per send, so the store
    /// follows the endpoint appearing/disappearing between messages.
    var discoveryReader: @Sendable () -> LocalEndpointInfo?

    /// Supplies an initial model preference. Defaults to the daemon-state
    /// file's `currentModel` — the same truth `ProviderStore` renders (the
    /// ownership boundary keeps the chat view from reaching across stores).
    /// When no explicit selection exists, use this preference only if the
    /// current endpoint catalog contains it; otherwise use the first model.
    /// Every send/retry validates its captured selection with `GET /models`.
    var modelProvider: @Sendable () -> String?

    /// Resolves PID + kernel start identity immediately before any request.
    /// A PID-only existence check could send the bearer token or prompt to an
    /// unrelated process after PID reuse.
    var processIdentityReader: @Sendable (Int32) -> ProcessIdentity?

    var probeClientFactory: @Sendable (LocalEndpointInfo) -> LocalEndpointClient
    var clientFactory: @Sendable (LocalEndpointInfo) -> LocalEndpointClient

    init(
        discoveryReader: @escaping @Sendable () -> LocalEndpointInfo? = {
            LocalEndpointDiscovery.readInfo()
        },
        modelProvider: @escaping @Sendable () -> String? = {
            DaemonStateFile.read()?.currentModel
        },
        processIdentityReader: @escaping @Sendable (Int32) -> ProcessIdentity? = {
            ProcessIdentity.read(pid: $0)
        },
        clientFactory: (@Sendable (LocalEndpointInfo) -> LocalEndpointClient)? = nil,
        probeClientFactory: (@Sendable (LocalEndpointInfo) -> LocalEndpointClient)? = nil
    ) {
        self.discoveryReader = discoveryReader
        self.modelProvider = modelProvider
        self.processIdentityReader = processIdentityReader
        self.clientFactory = clientFactory ?? { LocalEndpointClient(info: $0) }
        self.probeClientFactory = probeClientFactory ?? clientFactory ?? {
            LocalEndpointClient(info: $0, timeout: 2.5)
        }
    }
}
