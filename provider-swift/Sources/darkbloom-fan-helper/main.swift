import Dispatch
import FanControlCore
import FanControlIPC
import Foundation
import Darwin

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(
        Data(("fan-helper: \(message)\n").utf8)
    )
    exit(EXIT_FAILURE)
}

let controller: FanLeaseController
do {
    controller = try FanLeaseController()
} catch {
    fail(error.localizedDescription)
}

let delegate = FanHelperListener(controller: controller)
let listener = NSXPCListener(
    machServiceName: FanControlIPC.machServiceName
)
listener.delegate = delegate
listener.resume()

var signalSources: [DispatchSourceSignal] = []
for signalNumber in [SIGTERM, SIGINT, SIGHUP, SIGQUIT] {
    signal(signalNumber, SIG_IGN)
    let source = DispatchSource.makeSignalSource(
        signal: signalNumber,
        queue: .global(qos: .userInitiated)
    )
    source.setEventHandler {
        do {
            try controller.shutdown()
            exit(EXIT_SUCCESS)
        } catch {
            fail(error.localizedDescription)
        }
    }
    source.resume()
    signalSources.append(source)
}

dispatchMain()
