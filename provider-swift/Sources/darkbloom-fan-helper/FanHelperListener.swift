import FanControlCore
import FanControlIPC
import Foundation

final class FanHelperListener: NSObject, NSXPCListenerDelegate {
    private let controller: FanLeaseController

    init(controller: FanLeaseController) {
        self.controller = controller
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

        let session = FanHelperSession(controller: controller)
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
