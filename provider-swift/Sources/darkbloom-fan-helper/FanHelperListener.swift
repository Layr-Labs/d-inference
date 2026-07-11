import FanControlCore
import FanControlIPC
import Foundation

final class FanHelperListener: NSObject, NSXPCListenerDelegate {
    private let provider: FanControllerProvider

    init(provider: FanControllerProvider) {
        self.provider = provider
    }

    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection connection: NSXPCConnection
    ) -> Bool {
        connection.setCodeSigningRequirement(
            FanControlIPC.clientRequirement
        )
        connection.exportedInterface = NSXPCInterface(
            with: FanControlXPCProtocol.self
        )

        let session = FanHelperSession(provider: provider)
        connection.exportedObject = session
        connection.invalidationHandler = { [weak session] in
            session?.connectionInvalidated()
        }
        connection.interruptionHandler = { [weak session] in
            session?.connectionInvalidated()
        }
        connection.resume()
        return true
    }
}
