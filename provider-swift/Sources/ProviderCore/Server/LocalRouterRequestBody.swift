import Foundation
import NIOCore
import NIOFoundationCompat

/// What the router reads from a request body: only on a request it passes on, never on this Mac's path.
enum LocalRouterRequestBody {
    /// The request's `model`, for the checks before a `self` hop; nil when the body isn't a JSON object naming one.
    static func model(in body: ByteBuffer) -> String? {
        let object = (try? JSONSerialization.jsonObject(with: Data(buffer: body), options: [])) as? [String: Any]
        return object?["model"] as? String
    }
}
