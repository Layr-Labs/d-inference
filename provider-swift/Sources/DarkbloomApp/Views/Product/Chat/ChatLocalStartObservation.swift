import SwiftUI

/// Keep observation on PrivateChatView's stable identity. Moving the composer
/// after the first message or expanding diagnostics must not stop monitoring.
struct ChatLocalStartObservation: ViewModifier {
    let store: LocalAPIStore?
    let library: ModelLibraryStore?
    let chat: ChatStore
    let onRefreshConnection: () -> Void

    func body(content: Content) -> some View {
        content
            .task {
                guard chat.isLive, let store, let library else { return }
                store.startMonitoring()
                await library.start()
            }
            .onChange(of: library?.models, initial: true) { _, models in
                guard chat.isLive, let store, let models else { return }
                store.syncLocalModelSelection(preferredID: library?.selectedModelID, models: models)
            }
            .onChange(of: library?.selectedModelID, initial: true) { _, selectedID in
                guard chat.isLive, let store, let library else { return }
                store.syncLocalModelSelection(preferredID: selectedID, models: library.models)
            }
            .onChange(of: store?.localStart.state, initial: true) { _, state in
                guard chat.isLive, library != nil, let state else { return }
                switch state {
                case .ready, .cancelled, .failed:
                    onRefreshConnection()
                case .idle, .starting, .waitingForEndpoint, .cancelling:
                    break
                }
            }
            .onChange(of: store?.endpoint.map(ChatEndpointObservationKey.init)) { _, _ in
                // External endpoints are independently validated by ChatStore;
                // observing one never starts or adopts its process.
                guard chat.isLive, library != nil else { return }
                onRefreshConnection()
            }
            .onDisappear {
                // App ownership survives navigation; only application quit or
                // an explicit End session action shuts down the owned process.
                guard chat.isLive, library != nil else { return }
                store?.stopMonitoring()
            }
    }

}

/// Discovery timestamps can change without a new connection. Avoid flickering
/// the composer into a checking state on every background discovery update.
private struct ChatEndpointObservationKey: Equatable {
    let baseURL: URL
    let apiKey: String?
    let pid: Int32
    let health: LocalAPIHealth
    let models: LocalAPIModelCatalog

    init(_ endpoint: LocalAPIEndpointSnapshot) {
        baseURL = endpoint.baseURL
        apiKey = endpoint.apiKey
        pid = endpoint.pid
        health = endpoint.health
        models = endpoint.modelCatalog
    }
}
