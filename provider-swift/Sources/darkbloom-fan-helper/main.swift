import Dispatch
import FanControlIPC
import Foundation
import Darwin

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(
        Data(("fan-helper: \(message)\n").utf8)
    )
    exit(EXIT_FAILURE)
}

let provider = FanControllerProvider()
provider.prepare()
let delegate = FanHelperListener(provider: provider)
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
            try provider.shutdown()
            exit(EXIT_SUCCESS)
        } catch {
            fail(error.localizedDescription)
        }
    }
    source.resume()
    signalSources.append(source)
}

dispatchMain()
