import Foundation
import DarkbloomClusterProtocol

/// Delivers one worker's events to the request they name, for a pair that
/// serves several requests at once (continuous batching). The worker's event
/// stream stays one ordered stream; whichever waiting request finds no event
/// of its own pulls the next one from the endpoint and files it by request ID.
/// No thread of its own: a waiter pulls in bounded slices and hands the
/// endpoint to the next waiter between them.
final class ClusterWorkerEventRouter: @unchecked Sendable {
    private let endpoint: any ClusterWorkerEndpoint
    private let condition = NSCondition()
    private var mailboxes: [UUID?: [ClusterWorkerEventFrame]] = [:]
    private var pulling = false
    private var fault: Error?
    /// Events filed for a request nobody waits for any more are dropped
    /// beyond this many in total.
    private static let mailboxBound = 4096
    private static let sliceNanoseconds: UInt64 = 20_000_000

    init(endpoint: any ClusterWorkerEndpoint) { self.endpoint = endpoint }

    func receive(for requestID: UUID?, until deadline: UInt64, cancelled: () -> Bool) throws -> ClusterWorkerEventFrame {
        condition.lock()
        defer { condition.unlock() }
        while true {
            if var box = mailboxes[requestID], !box.isEmpty {
                let first = box.removeFirst()
                mailboxes[requestID] = box.isEmpty ? nil : box
                return first
            }
            if let fault { throw fault }
            if cancelled() { throw ClusterWorkerOwnerError.cancelled }
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else { throw ClusterWorkerOwnerError.deadline }
            if pulling {
                _ = condition.wait(until: Date(timeIntervalSinceNow: 0.02))
                continue
            }
            pulling = true
            let slice = min(deadline, now + Self.sliceNanoseconds)
            condition.unlock()
            var frame: ClusterWorkerEventFrame?
            var failure: Error?
            do {
                frame = try endpoint.receiveWorkerEvent(until: slice, cancelled: cancelled)
            } catch ClusterWorkerOwnerError.deadline where DispatchTime.now().uptimeNanoseconds >= slice {
                // The slice ended with no event: not a fault.
            } catch ClusterWorkerOwnerError.cancelled {
                // This waiter's own cancellation; others keep pulling.
            } catch {
                failure = error
            }
            condition.lock()
            pulling = false
            if let failure { fault = fault ?? failure }
            if let frame {
                let total = mailboxes.values.reduce(0) { $0 + $1.count }
                if total < Self.mailboxBound { mailboxes[frame.requestID, default: []].append(frame) }
            }
            condition.broadcast()
        }
    }
}
