import Foundation
import Hummingbird

/// Holds HTTP ownership through body.finish (including slow consumers), not
/// merely until the model engine has emitted its last token.
final class LocalResponseTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var accepting = true
    private var count = 0
    var activeCount: Int { lock.withLock { count } }
    func setAccepting(_ value: Bool) { lock.withLock { accepting = value } }

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
