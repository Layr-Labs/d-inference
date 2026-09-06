import Foundation

/// Downloads a profile with an inclusive limit on actual received body bytes.
/// The request retains its URLSession timeout; Content-Length is only an early
/// rejection hint. Own the byte stream's task so every exit cancels further IO.
enum EnrollmentProfileTransport {
    static func fetchProfile(
        _ request: URLRequest,
        using session: URLSession = .shared
    ) async throws -> (Data, URLResponse) {
        try Task.checkCancellation()
        let (bytes, response) = try await session.bytes(for: request)
        return try await withTaskCancellationHandler {
            defer { bytes.task.cancel() }
            try Task.checkCancellation()

            let maximumBytes = EnrollmentProfileResponse.maximumBytes
            guard response.expectedContentLength <= Int64(maximumBytes) else {
                throw EnrollmentError.profileResponseTooLarge(
                    maximumBytes: maximumBytes
                )
            }

            var data = Data()
            if response.expectedContentLength > 0 {
                data.reserveCapacity(Int(response.expectedContentLength))
            }
            for try await byte in bytes {
                try Task.checkCancellation()
                // Check BEFORE appending, including when the peer omits or
                // understates Content-Length. Never accumulate an extra byte.
                guard data.count < maximumBytes else {
                    throw EnrollmentError.profileResponseTooLarge(
                        maximumBytes: maximumBytes
                    )
                }
                data.append(byte)
            }
            try Task.checkCancellation()
            return (data, response)
        } onCancel: {
            // Also interrupt a stalled next() immediately; checking only inside
            // the loop would depend on the peer sending another byte.
            bytes.task.cancel()
        }
    }
}
