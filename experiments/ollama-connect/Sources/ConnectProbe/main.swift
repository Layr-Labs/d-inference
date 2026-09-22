import ConnectCore
import Foundation

if CommandLine.arguments.contains("--ollama-only") {
    let inventory = await OllamaDiscovery.discover()
    let data = try JSONSerialization.data(withJSONObject: ["reachable": inventory.reachable, "models": inventory.models.map(\.name)], options: [.sortedKeys])
    print(String(decoding: data, as: UTF8.self))
    exit(0)
}
let snapshot = await ConnectSnapshot.capture()
let report: [String: Any] = [
    "observed_at": ISO8601DateFormatter().string(from: snapshot.observedAt),
    "ollama_source": snapshot.ollama.source,
    "ollama_models": snapshot.ollama.models.map(\.name),
    "worker_signature_valid": snapshot.worker != nil,
    "worker_version": snapshot.local?.version ?? "unavailable",
    "running_process_verified": snapshot.processVerified,
    "network_status_available": snapshot.remoteAvailable,
    "local_decision_age_seconds": Date().timeIntervalSince1970 - (snapshot.local?.trust?.received_at ?? 0),
    "app_attest_corroborated": snapshot.evidence.isCurrent(at: Date().timeIntervalSince1970),
    "catalog_available": snapshot.catalogAvailable,
    "catalog_models": snapshot.catalog.map { ["id": $0.id, "limitation": CatalogPolicy.limitation($0, memoryGB: MacHardware.memoryGB, chip: MacHardware.chip) ?? "provider validation required"] },
    "ollama_network_policy": "fixed metadata GET endpoints only",
    "scope": "Read-only metadata and current coordinator authorization; no inference issued by the companion."
]
let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
print(String(decoding: data, as: UTF8.self))
