// Local completion metadata, never encoded into the wire protocol.
import Foundation

extension OutboundMessage {
    var onWritten: (@Sendable () -> Void)? {
        if case .codeAttestationResponse(_, _, let completion) = self { return completion }
        return nil
    }
}
