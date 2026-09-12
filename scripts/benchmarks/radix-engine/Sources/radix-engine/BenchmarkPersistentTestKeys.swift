import Foundation
#if RADIX_CANDIDATE
@_spi(Benchmarking) import ProviderCore
#endif

/// Standalone-only key selection and provenance. No key material is captured.
struct BenchmarkPersistentTestKeys: Sendable {
    #if RADIX_CANDIDATE
    let namespace: SSDPersistentTestKeyNamespace
    #endif
    let provenance: [String: String]

    static func parse(
        identifier: String?, accessGroup: String?, cacheMode: String,
        requirePersistentKey: Bool, nativeKVProbeOnly: Bool, environment: [String: String]
    ) throws -> Self? {
        guard identifier != nil || accessGroup != nil else { return nil }
        guard let identifier, let accessGroup,
            let uuid = UUID(uuidString: identifier), cacheMode == "ssd",
            requirePersistentKey, !nativeKVProbeOnly
        else {
            throw RadixBenchmark.Failure.message(
                "persistent test keys require both UUID namespace and access group, SSD persistent-key mode, and the serving path")
        }
        #if RADIX_CANDIDATE
        let namespace = try SSDPersistentTestKeyNamespace(identifier: uuid, accessGroup: accessGroup)
        try namespace.validate(environment: environment, requirePersistentKey: requirePersistentKey)
        return Self(namespace: namespace, provenance: Self.provenance(namespace, environment: environment))
        #else
        throw RadixBenchmark.Failure.message("persistent test keys require the candidate artifact")
        #endif
    }

    /// Repeat at loader entry, before config/model/metallib work. A changed
    /// environment cannot make the recorded root differ from the executed root.
    func validate(environment: [String: String]) throws {
        #if RADIX_CANDIDATE
        try namespace.validate(environment: environment)
        guard provenance == Self.provenance(namespace, environment: environment) else {
            throw RadixBenchmark.Failure.message("persistent test key context changed after argument validation")
        }
        #endif
    }

    func observedProvenance(keyMode: String?) -> [String: Any] {
        var result = provenance.mapValues { $0 as Any }
        result["actual_key_mode"] = keyMode as Any? ?? NSNull()
        return result
    }

    func requireObservedMode(_ keyMode: String?, cacheEnabled: Bool) throws {
        guard !cacheEnabled || keyMode == "persistent" else {
            throw RadixBenchmark.Failure.message("namespaced SSD cache did not report persistent key mode")
        }
    }

    #if RADIX_CANDIDATE
    private static func provenance(
        _ namespace: SSDPersistentTestKeyNamespace, environment: [String: String]
    ) -> [String: String] {
        // The public namespace validator has already required this absolute root.
        let root = environment["DARKBLOOM_PREFIX_CACHE_TEST_ROOT"]!
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return [
            "namespace": namespace.identifier.uuidString.lowercased(),
            "access_group": namespace.accessGroup,
            "enclave_label": namespace.enclaveLabel,
            "wrapped_kek_service": namespace.wrappedKEKService,
            "wrapped_kek_account": namespace.wrappedKEKAccount,
            "isolated_root": URL(fileURLWithPath: root, isDirectory: true).standardizedFileURL.path,
            "requested_key_mode": "persistent",
        ]
    }
    #endif
}
