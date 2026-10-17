import Foundation

/// The closure owns this guard even before Hummingbird invokes its writer. A
/// discarded body/header-write failure cannot strand the HTTP response hold.
/// This guard has no lease or terminal/usage authority.
final class DistributedHTTPBodyLifetime: Sendable {
    private let response: DistributedHTTPResponse
    init(_ response: DistributedHTTPResponse) { self.response = response }
    func completed() { response.finish() }
    deinit {
        response.disconnect()
        response.finish()
    }
}
