import Foundation
import Hummingbird

/// Holds HTTP ownership through body.finish (including slow consumers), not
/// merely until the model engine has emitted its last token.
final class LocalResponseTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var accepting = true
    /// A pair's API only (`setPairServes`): whether its pair takes requests now. Nil on every other API.
    private var pairServes: Bool?
    private var count = 0
    var activeCount: Int { lock.withLock { count } }
    func setAccepting(_ value: Bool) { lock.withLock { accepting = value } }
    /// A pair's leader: whether its pair takes requests now (its slot's admission opened: published, past its warmup
    /// canary, not retiring). `LocalPairGateResponder` reads it on every POST, without waiting for the loop.
    func setPairServes(_ value: Bool) { lock.withLock { pairServes = value } }
    /// The pair this API serves doesn't take requests now; false on every other API.
    var pairRefuses: Bool { lock.withLock { pairServes == false } }

    func admit() throws -> Lease {
        try lock.withLock {
            guard accepting else { throw HTTPError(.serviceUnavailable, message: "provider draining; retry elsewhere") }
            count += 1
            return Lease(self)
        }
    }

    final class Lease: @unchecked Sendable {
        private let lock = NSLock()
        private var tracker: LocalResponseTracker?
        init(_ tracker: LocalResponseTracker) { self.tracker = tracker }
        func release() {
            let owner = lock.withLock { let owner = tracker; tracker = nil; return owner }
            if let owner { owner.lock.withLock { owner.count -= 1 } }
        }
        deinit { release() }
        func wrap(_ response: Response) -> Response {
            var response = response
            let body = response.body
            response.body = ResponseBody(contentLength: body.contentLength) { [self] writer in
                defer { release() }
                try await body.write(writer)
            }
            return response
        }
    }
}
