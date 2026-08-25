import Foundation

enum EnrollmentProfileResponse {
    static let supportedMediaType = "application/x-apple-aspen-config"
    static let maximumBytes = 1_048_576

    static func validate(
        data: Data,
        response: URLResponse
    ) throws {
        guard let http = response as? HTTPURLResponse else {
            throw EnrollmentError.invalidProfileResponse(
                "the response was not HTTP"
            )
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            let body = String(
                decoding: data.prefix(4_096),
                as: UTF8.self
            )
            throw EnrollmentError.coordinatorReturnedHTTP(
                http.statusCode,
                body: body
            )
        }
        guard let contentType = http.value(
            forHTTPHeaderField: "Content-Type"
        ), isSupportedMediaType(contentType) else {
            let received = http.value(forHTTPHeaderField: "Content-Type")
                ?? "<missing>"
            throw EnrollmentError.invalidProfileResponse(
                "expected \(supportedMediaType), received \(received)"
            )
        }
        guard !data.isEmpty else {
            throw EnrollmentError.invalidProfileResponse(
                "the response body was empty"
            )
        }
        if http.expectedContentLength > Int64(maximumBytes)
            || data.count > maximumBytes
        {
            throw EnrollmentError.profileResponseTooLarge(
                maximumBytes: maximumBytes
            )
        }
    }

    private static func isSupportedMediaType(_ rawValue: String) -> Bool {
        // Media type tokens are case-insensitive. Parameters are allowed, but
        // an ambiguous comma-joined value is not: Content-Type is a singleton
        // response field and accepting only its first member could hide a
        // proxy-injected HTML/JSON type.
        guard !rawValue.contains(",") else { return false }
        let baseType = rawValue
            .split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return baseType?.caseInsensitiveCompare(supportedMediaType)
            == .orderedSame
    }
}
