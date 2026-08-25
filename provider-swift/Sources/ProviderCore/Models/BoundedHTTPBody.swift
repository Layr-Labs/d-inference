import Foundation

/// Streams an HTTP body into memory with an inclusive byte ceiling.
///
/// Content-Length is only an early rejection signal; the streamed byte count
/// remains authoritative so omitted or dishonest headers cannot bypass limits.
enum BoundedHTTPBody {
    struct LimitExceeded: Error, CustomStringConvertible, LocalizedError, Sendable {
        let responseName: String
        let maximumBytes: Int

        var description: String {
            "\(responseName) exceeds \(maximumBytes)-byte bound"
        }

        var errorDescription: String? { description }
    }

    static func read(
        using urlSession: URLSession,
        request: URLRequest,
        maximumBytes: Int,
        responseName: String
    ) async throws -> (Data, URLResponse) {
        let (bytes, response) = try await urlSession.bytes(for: request)
        if response.expectedContentLength > Int64(maximumBytes) {
            throw LimitExceeded(
                responseName: responseName,
                maximumBytes: maximumBytes)
        }

        var data = Data()
        if response.expectedContentLength > 0 {
            data.reserveCapacity(min(Int(response.expectedContentLength), maximumBytes))
        }
        for try await byte in bytes {
            guard data.count < maximumBytes else {
                throw LimitExceeded(
                    responseName: responseName,
                    maximumBytes: maximumBytes)
            }
            data.append(byte)
        }
        return (data, response)
    }
}
