import Foundation

/// One entry of the coordinator operator's approval file
/// (`darkbloom_cluster_pair_catalog_v1`), saved field for field so the member
/// derives the same canonical policy bytes the coordinator does. Mirrors
/// `nativeRuntimeApprovalFile` and `canonicalNativeRuntimeApproval`
/// (coordinator/registry/native_pair_catalog_file.go, native_pair_approval.go).
/// Saving an entry approves nothing: only the coordinator's own file can.
public struct ClusterPairApproval: Codable, Sendable, Equatable {
    public let id: String
    public let model: String
    public let generation: UInt64
    public let planSHA256: String
    public let artifactSHA256: String
    public let nativeRuntimeSHA256: String
    public let metallibSHA256: String
    public let resourceLibrarySHA256: String
    public let capabilitySHA256: String
    public let resourcePolicySHA256: String
    public let profileSHA256: String
    public let schedule: UInt8
    public let maximumTransportFrame: UInt32
    public let maximumPlaintext: UInt32
    public let maximumRecords: UInt64
    public let maximumCumulativePlaintext: UInt64
    public let allowedChips: [String]
    public let notAfter: String

    enum CodingKeys: String, CodingKey, CaseIterable {
        case id, model, generation, schedule
        case planSHA256 = "plan_sha256"
        case artifactSHA256 = "artifact_sha256"
        case nativeRuntimeSHA256 = "native_runtime_sha256"
        case metallibSHA256 = "metallib_sha256"
        case resourceLibrarySHA256 = "resource_library_sha256"
        case capabilitySHA256 = "capability_sha256"
        case resourcePolicySHA256 = "resource_policy_sha256"
        case profileSHA256 = "profile_sha256"
        case maximumTransportFrame = "maximum_transport_frame"
        case maximumPlaintext = "maximum_plaintext"
        case maximumRecords = "maximum_records"
        case maximumCumulativePlaintext = "maximum_cumulative_plaintext"
        case allowedChips = "allowed_chips"
        case notAfter = "not_after"
    }
    static let fields = Set(CodingKeys.allCases.map(\.rawValue))

    /// The exact bytes the coordinator hashes into `policy_sha256` and sends
    /// in every prepare frame. Every bound is enforced by the one strict
    /// reader, so an entry the coordinator would refuse never encodes.
    func canonicalPolicy() throws -> Data {
        guard let expiry = Self.unixNanoseconds(rfc3339: notAfter) else {
            throw ClusterConfigurationError.invalid("Pair approval not_after must be an RFC 3339 instant")
        }
        var bytes = Data("darkbloom/coordinator-native-runtime-approval/v1\0".utf8)
        func integer<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.bigEndian) { bytes.append(contentsOf: $0) }
        }
        func text(_ value: String) { integer(UInt32(value.utf8.count)); bytes.append(contentsOf: value.utf8) }
        text(id); text(model); integer(generation)
        for digest in [planSHA256, artifactSHA256, nativeRuntimeSHA256, metallibSHA256,
                       resourceLibrarySHA256, capabilitySHA256, resourcePolicySHA256, profileSHA256] {
            guard ClusterConfigurationSyntax.hash(digest) else {
                throw ClusterConfigurationError.invalid("Pair approval digests must be 64 lowercase hex characters")
            }
            let digits = Array(digest.utf8).map { $0 < 58 ? $0 - 48 : $0 - 87 }
            for index in stride(from: 0, to: 64, by: 2) { bytes.append(digits[index] << 4 | digits[index + 1]) }
        }
        bytes.append(contentsOf: [1, 1, schedule])
        integer(maximumTransportFrame); integer(maximumPlaintext)
        integer(maximumRecords); integer(maximumCumulativePlaintext)
        integer(expiry); integer(UInt32(allowedChips.count))
        allowedChips.forEach(text)
        guard (try? NativePairMemberPolicy(bytes)) != nil else {
            throw ClusterConfigurationError.invalid("Pair approval is outside the coordinator's policy bounds")
        }
        return bytes
    }

    /// `YYYY-MM-DDTHH:MM:SS[.fraction](Z|±HH:MM)` as nanoseconds since 1970.
    /// Deliberately no laxer than Go's `time.Parse(time.RFC3339, …)`: a form
    /// this refuses is an error here, never a different instant.
    static func unixNanoseconds(rfc3339 text: String) -> UInt64? {
        let b = Array(text.utf8)
        func number(_ range: Range<Int>) -> Int? {
            guard range.upperBound <= b.count else { return nil }
            var value = 0
            for digit in b[range] {
                guard (48...57).contains(digit) else { return nil }
                value = value * 10 + Int(digit - 48)
            }
            return value
        }
        guard b.count >= 20, b[4] == 45, b[7] == 45, b[10] == 84, b[13] == 58, b[16] == 58,
              let year = number(0..<4), let month = number(5..<7), let day = number(8..<10),
              let hour = number(11..<13), let minute = number(14..<16), let second = number(17..<19),
              (1...12).contains(month), hour < 24, minute < 60, second < 60 else { return nil }
        let leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
        let lengths = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        guard (1...lengths[month - 1]).contains(day) else { return nil }
        var index = 19, nanoseconds = 0
        if b[index] == 46 {
            let start = index + 1
            index = start
            while index < b.count, (48...57).contains(b[index]) { index += 1 }
            guard (1...9).contains(index - start), let fraction = number(start..<index) else { return nil }
            nanoseconds = fraction
            for _ in (index - start)..<9 { nanoseconds *= 10 }
        }
        var offset = 0
        guard index < b.count else { return nil }
        if b[index] == 90 {
            guard index + 1 == b.count else { return nil }
        } else {
            guard b[index] == 43 || b[index] == 45, index + 6 == b.count, b[index + 3] == 58,
                  let hours = number((index + 1)..<(index + 3)), let minutes = number((index + 4)..<(index + 6)),
                  hours < 24, minutes < 60 else { return nil }
            offset = (hours * 3600 + minutes * 60) * (b[index] == 43 ? 1 : -1)
        }
        // Days since 1970-01-01 in the proleptic Gregorian calendar.
        let shifted = month <= 2 ? year - 1 : year
        let era = shifted / 400, yearOfEra = shifted - era * 400
        let dayOfYear = (153 * (month > 2 ? month - 3 : month + 9) + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        let seconds = (era * 146_097 + dayOfEra - 719_468) * 86_400 + hour * 3600 + minute * 60 + second - offset
        guard seconds > 0, seconds <= (Int(Int64.max) - nanoseconds) / 1_000_000_000 else { return nil }
        return UInt64(seconds) * 1_000_000_000 + UInt64(nanoseconds)
    }
}
