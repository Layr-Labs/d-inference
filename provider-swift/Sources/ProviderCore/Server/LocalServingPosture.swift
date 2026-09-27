import MLXLMCommon

/// Read-only facts captured from a live bridge. Missing facts stay absent;
/// ready state and a persistent key do not by themselves prove a cache hit.
struct LocalServingPosture: Sendable {
    let backend: EngineV2KVBackendKind
    let capacity: CBv2CapacitySnapshot
    let pageSize: Int?
    let prefix: PrefixCacheModelStatus
    let completeKeyPersistent: Bool?
}

extension EngineV2Bridge {
    func localMetricsSample(model: String) -> MTPSlotMetricsSample? {
        guard ownedEngine != nil else { return nil }
        return .init(model: model, snapshot: mtpStatusSnapshot(), posture: .init(
            backend: kvBackendKind, capacity: capacitySnapshot(), pageSize: pagedPageSize,
            prefix: prefixCacheModelStatus(),
            completeKeyPersistent: ssdHybridCheckpointStore.map { !$0.usesEphemeralKey }))
    }
}

enum LocalServingPostureRenderer {
    static func render(_ samples: [MTPSlotMetricsSample]) -> String {
        var families: [String: [String]] = [:]
        func add(_ name: String, _ labels: String, _ value: Int) {
            families[name, default: []].append("\(name){\(labels)} \(value)")
        }
        for sample in samples {
            guard let posture = sample.posture else { continue }
            let model = "model=\"\(MTPPrometheusRenderer.escapeLabel(sample.model))\""
            add("kv_backend_info", model + ",backend=\"\(posture.backend.rawValue)\"", 1)
            add("kv_active_requests", model, posture.capacity.activeRequests)
            add("kv_waiting_requests", model, posture.capacity.waitingRequests)
            if posture.backend == .paged {
                if let pageSize = posture.pageSize { add("paged_kv_page_size", model, pageSize) }
                if let storage = posture.capacity.pagedStorage {
                    add("paged_kv_live_bytes", model, storage.livePageBytes)
                    add("paged_kv_reserved_bytes", model, storage.reservedPageBytes)
                    add("paged_kv_grant_bytes", model, storage.grantBytes)
                    add("paged_kv_committed_bytes", model, storage.committedBytes)
                }
            }
            let prefix = posture.prefix
            add("prefix_cache_status", model + ",state=\"\(prefix.state.rawValue)\",reason=\"\(prefix.reason.rawValue)\"", 1)
            if let persistent = posture.completeKeyPersistent {
                add("complete_prefix_key_persistent", model, persistent ? 1 : 0)
            }
        }
        return families.keys.sorted().map { name in
            "# TYPE \(name) gauge\n" + families[name]!.joined(separator: "\n") + "\n"
        }.joined()
    }
}
