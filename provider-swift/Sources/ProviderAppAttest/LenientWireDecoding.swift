import Foundation

/// Decodes a snake_case wire key whether or not the decoder converted keys.
/// The coordinator wire uses plain JSON coders; the daemon state file applies
/// `.convertFromSnakeCase`, which rewrites `opt_in_entitlement` to
/// `optInEntitlement` before lookup. A value of the wrong type or an enum
/// case this build does not know decodes as absent, never as a failure.
struct WireKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init(_ stringValue: String) { self.stringValue = stringValue }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

extension KeyedDecodingContainer where K == WireKey {
    func lenient<T: Decodable>(_ snakeKey: String) -> T? {
        let wanted = Self.normalized(snakeKey)
        guard let key = allKeys.first(where: { Self.normalized($0.stringValue) == wanted }) else { return nil }
        return try? decodeIfPresent(T.self, forKey: key)
    }

    /// Case- and underscore-insensitive: `generations_last_24h`,
    /// `generationsLast24h` and `generationsLast24H` all match.
    static func normalized(_ key: String) -> String {
        key.lowercased().replacingOccurrences(of: "_", with: "")
    }
}
