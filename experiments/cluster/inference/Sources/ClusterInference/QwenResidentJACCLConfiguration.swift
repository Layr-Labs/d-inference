import Foundation

/// Configuration admission only. This does not verify physical devices,
/// connectivity, available memory, or permission to execute a model.
struct QwenResidentJACCLConfiguration {
    static let maximumMatrixBytes = 4096

    struct Receipt: Encodable, Equatable {
        let backend = "jaccl", topology = "mesh", worldSize = 2
        let configuredRank: Int
        let deviceMatrixPath: String, deviceMatrixSHA256: String
        let coordinator: String, localDevice: String
        let configurationFingerprint: String
        let physicalDeviceIdentityVerified = false, physicalTransferQualified = false
    }

    private struct Environment: Equatable {
        let rank: Int, matrixPath: String, coordinator: String
    }

    private let environment: Environment
    private let matrixBytes: Data
    let receipt: Receipt
    var rank: Int { environment.rank }
    var fingerprint: String { receipt.configurationFingerprint }

    private init(environment: Environment, matrixBytes: Data, devices: [String]) throws {
        let matrixSHA256 = sha256(matrixBytes)
        // The local path and rank may differ between Macs. The raw matrix and
        // coordinator must agree, in addition to the existing request/source Plan.
        let common = try canonicalJSONData([
            "schema": "qwen_resident_jaccl_configuration_v1", "backend": "jaccl",
            "topology": "mesh", "worldSize": "2", "deviceMatrixSHA256": matrixSHA256,
            "coordinator": environment.coordinator,
        ])
        self.environment = environment
        self.matrixBytes = matrixBytes
        receipt = .init(configuredRank: environment.rank, deviceMatrixPath: environment.matrixPath,
            deviceMatrixSHA256: matrixSHA256, coordinator: environment.coordinator,
            localDevice: devices[environment.rank], configurationFingerprint: sha256(common))
    }

    /// Injected IO permits actual admission to be exercised by CPU fixtures.
    /// Runtime callers supply ProcessInfo.environment and the bounded reader.
    static func admit(environment values: [String: String], read: (URL, Int) throws -> Data) throws -> Self {
        let environment = try parseEnvironment(values)
        let bytes = try read(URL(fileURLWithPath: environment.matrixPath), maximumMatrixBytes)
        let devices = try parseMatrix(bytes)
        return try .init(environment: environment, matrixBytes: bytes, devices: devices)
    }

    /// Recheck immediately before and after JACCL initialization, before loading.
    /// JACCL opens the path itself; this is a bounded drift check, not atomic
    /// attestation of that native file open or the physical link it initializes.
    func requireUnchanged(environment values: [String: String], read: (URL, Int) throws -> Data) throws {
        guard try Self.parseEnvironment(values) == environment,
              try read(URL(fileURLWithPath: environment.matrixPath), Self.maximumMatrixBytes) == matrixBytes else {
            throw ProbeError("Resident JACCL configuration changed around native initialization")
        }
    }

    func requireInitialized(rank: Int, worldSize: Int, transport: ClusterTransport) throws {
        guard transport == .jaccl, rank == self.rank, worldSize == 2 else {
            throw ProbeError("Resident JACCL initialized a different backend, rank or world size")
        }
    }

    private static func parseEnvironment(_ values: [String: String]) throws -> Environment {
        // Native Config::from_env chooses the first PRESENT name, even empty.
        // Refuse conflicting aliases rather than silently hiding an old value.
        func selected(_ preferred: String, _ fallback: String) throws -> String {
            if let first = values[preferred], let second = values[fallback], first != second {
                throw ProbeError("Resident JACCL environment aliases conflict: \(preferred)/\(fallback)")
            }
            guard let value = values[preferred] ?? values[fallback], !value.isEmpty,
                  value.utf8.count <= 4096, !value.utf8.contains(0) else {
                throw ProbeError("Resident JACCL requires bounded nonempty \(preferred)/\(fallback)")
            }
            return value
        }
        guard values["JACCL_RING"] == nil, values["MLX_JACCL_RING"] == nil else {
            throw ProbeError("Resident JACCL requires its explicit two-rank mesh without ring overrides")
        }
        let rawRank = try selected("JACCL_RANK", "MLX_RANK")
        guard rawRank == "0" || rawRank == "1", let rank = Int(rawRank) else {
            throw ProbeError("Resident JACCL rank must be exactly 0 or 1")
        }
        let path = try selected("JACCL_IBV_DEVICES", "MLX_IBV_DEVICES")
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard path.hasPrefix("/"), components.count > 1,
              components.dropFirst().allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              !path.utf8.contains(where: { $0 < 32 || $0 == 127 }) else {
            throw ProbeError("Resident JACCL matrix must use a bounded normalized absolute file path")
        }
        let coordinator = try selected("JACCL_COORDINATOR", "MLX_JACCL_COORDINATOR")
        let endpoint = coordinator.split(separator: ":", omittingEmptySubsequences: false)
        func decimal(_ text: Substring, maximum: Int) -> Int? {
            guard !text.isEmpty, text.utf8.allSatisfy({ (48...57).contains($0) }),
                  let value = Int(text), value <= maximum, String(value) == text else { return nil }
            return value
        }
        guard endpoint.count == 2, let port = decimal(endpoint[1], maximum: 65535), port > 0 else {
            throw ProbeError("Resident JACCL coordinator requires a canonical IPv4 address and port")
        }
        let octets = endpoint[0].split(separator: ".", omittingEmptySubsequences: false)
        let numbers = octets.compactMap { decimal($0, maximum: 255) }
        guard octets.count == 4, numbers.count == 4, numbers[0] > 0, numbers[0] < 224 else {
            throw ProbeError("Resident JACCL coordinator must be a unicast IPv4 endpoint")
        }
        return .init(rank: rank, matrixPath: path, coordinator: coordinator)
    }

    private static func parseMatrix(_ bytes: Data) throws -> [String] {
        guard !bytes.isEmpty, bytes.count <= maximumMatrixBytes else {
            throw ProbeError("Resident JACCL device matrix exceeds its 4 KiB bound or is empty")
        }
        try validateWorkerJSON(bytes)
        guard let rows = try JSONSerialization.jsonObject(with: bytes) as? [[Any]],
              rows.count == 2, rows.allSatisfy({ $0.count == 2 }),
              rows[0][0] is NSNull, rows[1][1] is NSNull,
              let first = rows[0][1] as? String, let second = rows[1][0] as? String else {
            throw ProbeError("Resident JACCL requires exactly two mesh ranks, null diagonal and one device per peer")
        }
        for name in [first, second] {
            guard !name.isEmpty, name.utf8.count <= 63, name.utf8.allSatisfy({
                (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
                    || $0 == 95 || $0 == 45 || $0 == 46
            }) else { throw ProbeError("Resident JACCL device name is empty or outside its bounded identifier syntax") }
        }
        return [first, second]
    }
}

extension QwenResidentBenchmarkWorkerCLI {
    func admitTransport(environment: [String: String], read: (URL, Int) throws -> Data) throws
        -> QwenResidentJACCLConfiguration? {
        guard role == .rank, transport == .jaccl else { return nil }
        return try .admit(environment: environment, read: read)
    }
}
