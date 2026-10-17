import Foundation
import DarkbloomClusterProtocol

let fixtureReady: ClusterWorkerReady = {
    let path = ProcessInfo.processInfo.environment["FIXTURE_READY_PATH"]!
    let frame = try! ClusterWorkerCodec.decodeEvent(Data(contentsOf: URL(fileURLWithPath: path)))
    guard case .ready(let ready) = frame.event else { fatalError("fixture ready missing") }
    return ready
}()
let fixtureIdentity = fixtureReady.identity
let fixtureProfile = fixtureReady.profile
let fixturePlan = fixtureReady.executionPlanSHA256
