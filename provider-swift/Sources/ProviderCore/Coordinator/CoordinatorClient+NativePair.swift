// CoordinatorClient native-pair member driver binding: attaches the staged
// member control to the ACTUAL TLS connection only after nonce-bound member
// acceptance, dispatches native-pair public frames into it, and detaches it
// at every connection boundary. An ordinary WebSocket ACK, a supplied hash or
// a reconnect never activates or retains the driver.

import Foundation
import Network

extension CoordinatorClient {
    /// Binds the member control driver. Requires the member role, the exact
    /// negotiated nonce of THIS accepted connection, and the live TLS
    /// connection. The existing signer and transport remain responsible for
    /// member identity; this grants no trust or runtime approval by itself.
    internal func installNativePairMember(_ control: NativePairMemberControl) throws {
        guard config.executionRole == .clusterMember, sessionRegistered,
              memberRoleFailure == false,
              let nonce = memberNegotiation?.nonce, let connection = nwConnection,
              nativePairMember == nil, nativePairConnection == nil else {
            throw NativePairMemberError.unconfigured
        }
        let attachment = try control.attach(nonce: nonce, connection: connection)
        nativePairMember = control
        nativePairConnection = attachment
    }

    /// Native-pair public frames bypass the ordinary coordinator-message
    /// codec entirely: strict closed decode first, then the member control's
    /// own epoch/generation/sequence checks. A frame that fails either
    /// poisons the connection (the control detaches it).
    internal func consumeNativePairFrameIfPresent(_ data: Data) -> Bool {
        guard config.executionRole == .clusterMember,
              let control = nativePairMember, let connection = nativePairConnection,
              let message = try? NativePairMessage.decodePublicFrame(data),
              NativePairMessage.outboundTypes.contains(message.type) else { return false }
        let wall = Int64(Date().timeIntervalSince1970 * 1_000_000_000)
        do {
            try control.receive(message, on: connection,
                receivedAt: DispatchTime.now().uptimeNanoseconds, wallUnixNanoseconds: wall)
        } catch {
            // The control detached the connection on the contract violation.
        }
        return true
    }

    /// Every connection boundary drops the driver; nothing is retained across
    /// a reconnect. Cancellation requests native cleanup independently of any
    /// signer or WebSocket write.
    internal func detachNativePairMember() {
        guard let connection = nativePairConnection else {
            nativePairMember = nil
            return
        }
        nativePairConnection = nil
        nativePairMember?.detach(connection)
        nativePairMember = nil
    }
}
