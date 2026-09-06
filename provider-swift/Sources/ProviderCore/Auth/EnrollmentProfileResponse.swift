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
        let components = rawValue.split(
            separator: ";",
            omittingEmptySubsequences: false
        )
        guard let baseType = components.first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        else {
            return false
        }
        guard baseType.caseInsensitiveCompare(supportedMediaType)
            == .orderedSame
        else {
            return false
        }
        return components.dropFirst().allSatisfy(isSafeParameter)
    }

    private static func isSafeParameter(_ component: Substring) -> Bool {
        let parameter = component.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let pair = parameter.split(
            separator: "=",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        guard pair.count == 2, isToken(pair[0]) else { return false }
        let value = pair[1].trimmingCharacters(in: .whitespacesAndNewlines)
        if value.first == "\"", value.last == "\"", value.count >= 2 {
            return isSafeQuotedValue(value.dropFirst().dropLast())
        }
        return isToken(value)
    }

    private static func isToken<S: StringProtocol>(_ value: S) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy { byte in
            (byte >= 0x30 && byte <= 0x39)
                || (byte >= 0x41 && byte <= 0x5A)
                || (byte >= 0x61 && byte <= 0x7A)
                || "!#$%&'*+-.^_`|~".utf8.contains(byte)
        }
    }

    private static func isSafeQuotedValue(
        _ value: Substring
    ) -> Bool {
        var escaped = false
        for byte in value.utf8 {
            if escaped {
                guard byte == 0x09 || (byte >= 0x20 && byte < 0x7F) else {
                    return false
                }
                escaped = false
            } else if byte == 0x5C {
                escaped = true
            } else if byte == 0x22
                || (byte != 0x09 && (byte < 0x20 || byte >= 0x7F))
            {
                return false
            }
        }
        return !escaped
    }
}
