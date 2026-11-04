// Local completion metadata, never encoded into the wire protocol.
import Foundation

extension OutboundMessage {
    var onWritten: (@Sendable () -> Void)? {
        if case .codeAttestationResponse(_, _, let completion) = self { return completion }
        return nil
    }
}

extension CoordinatorClient {
    /// A written `models_update` joins the registered set
    /// (`ProviderState.registeredModelIDs`); other messages change nothing.
    nonisolated func registeredSetUpdate(_ message: OutboundMessage) -> (@Sendable () -> Void)? {
        guard case .modelsUpdate(let models) = message else { return nil }
        let state = self.state
        let ids = models.map(\.id)
        return { state.noteModelsUpdateWritten(ids) }
    }
}
