import Foundation

/// Decoding boundary for the two account-scoped coordinator responses used by
/// My Macs. A future API service can inject this protocol without leaking JSON
/// or Go timestamp conventions into the store.
protocol MyMacsWireDecoding: Sendable {
    func decodeProviders(from data: Data) throws -> MyMacsProvidersWireResponse
    func decodeSummary(from data: Data) throws -> MyMacsSummaryWireResponse
}

struct MyMacsWireDecoder: MyMacsWireDecoding {
    func decodeProviders(from data: Data) throws -> MyMacsProvidersWireResponse {
        try makeDecoder().decode(MyMacsProvidersWireResponse.self, from: data)
    }

    func decodeSummary(from data: Data) throws -> MyMacsSummaryWireResponse {
        try makeDecoder().decode(MyMacsSummaryWireResponse.self, from: data)
    }

    private func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let rawValue = try container.decode(String.self)
            guard let date = Self.parseGoRFC3339(rawValue) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Expected a Go RFC3339 or RFC3339Nano timestamp."
                )
            }
            return date
        }
        return decoder
    }

    private static func parseGoRFC3339(_ value: String) -> Date? {
        let wholeSeconds = ISO8601DateFormatter()
        wholeSeconds.formatOptions = [.withInternetDateTime]
        guard let decimalPoint = value.firstIndex(of: ".") else {
            return wholeSeconds.date(from: value)
        }

        let fractionalStart = value.index(after: decimalPoint)
        guard let timeZoneStart = value[fractionalStart...].firstIndex(where: {
            $0 == "Z" || $0 == "+" || $0 == "-"
        }) else {
            return nil
        }
        let digits = value[fractionalStart..<timeZoneStart]
        guard (1...9).contains(digits.count),
              digits.allSatisfy(\.isNumber),
              let numerator = UInt64(digits) else {
            return nil
        }

        let wholeValue = String(value[..<decimalPoint]) + String(value[timeZoneStart...])
        guard let wholeDate = wholeSeconds.date(from: wholeValue) else { return nil }
        let denominator = pow(10.0, Double(digits.count))
        return wholeDate.addingTimeInterval(Double(numerator) / denominator)
    }
}
