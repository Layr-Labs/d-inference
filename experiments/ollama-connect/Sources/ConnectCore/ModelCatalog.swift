import Foundation

public struct NetworkModel: Decodable, Identifiable, Sendable, Equatable {
    public let id: String
    public let display_name: String
    public let size_gb: Double
    public let min_ram_gb: Int?
    public let required_provider_capabilities: [String]?
    public let aggregate_sha256: String?
    public let active: Bool?
    public let version: String?
    public let model_type: String?
}

public enum CatalogPolicy {
    public static func validID(_ id: String) -> Bool {
        guard !id.isEmpty, id.utf8.count <= 200, id.first?.isASCII == true,
              id.first?.isLetter == true || id.first?.isNumber == true,
              !id.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else { return false }
        return id.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 46, 47, 95].contains($0) }
    }

    public static func decode(_ data: Data) throws -> [NetworkModel] {
        guard data.count <= 1_048_576 else { throw ConnectError.oversized }
        struct Envelope: Decodable { let models: [NetworkModel] }
        let models = try JSONDecoder().decode(Envelope.self, from: data).models
        guard models.count <= 256, Set(models.map(\.id)).count == models.count else { throw ConnectError.invalidResponse }
        return models.filter {
            validID($0.id) && $0.active == true && $0.model_type == "text"
                && !$0.display_name.isEmpty && $0.display_name.utf8.count <= 200
                && $0.size_gb.isFinite && $0.size_gb > 0
                && $0.aggregate_sha256?.count == 64
                && $0.aggregate_sha256?.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) == true
        }
    }

    /// Advisory only. The signed provider still enforces actual NAX capability,
    /// complete artifact hashes, activation/KV memory and routing eligibility.
    public static func limitation(_ model: NetworkModel, memoryGB: Int, chip: String) -> String? {
        if let minimum = model.min_ram_gb, memoryGB < minimum { return "Requires at least \(minimum) GB memory" }
        let required = Set(model.required_provider_capabilities ?? [])
        if !required.subtracting(["apple_m5", "mlx_nax"]).isEmpty { return "Requires a provider capability this companion cannot verify" }
        if required.contains("apple_m5") && !chip.contains("M5") { return "Requires Apple M5 and the NAX runtime" }
        return nil
    }
}
