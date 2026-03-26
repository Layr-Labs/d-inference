/// UpdateManager — Checks for app and binary updates.
///
/// Periodically checks the coordinator for the latest version and
/// notifies the user if an update is available.

import Foundation

@MainActor
final class UpdateManager: ObservableObject {

    @Published var updateAvailable = false
    @Published var latestVersion = ""
    @Published var currentVersion: String

    init() {
        currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
    }

    /// Check the coordinator for the latest version.
    func checkForUpdates(coordinatorURL: String) async {
        // Try the coordinator's version endpoint
        let baseURL = coordinatorURL
            .replacingOccurrences(of: "ws://", with: "http://")
            .replacingOccurrences(of: "wss://", with: "https://")
            .replacingOccurrences(of: "/ws/provider", with: "")

        guard let url = URL(string: "\(baseURL)/api/version") else { return }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let version = json["version"] as? String {
                latestVersion = version
                updateAvailable = isNewer(version, than: currentVersion)
            }
        } catch {
            // Silently fail — update check is optional
        }
    }

    /// Check if the dginf-provider binary needs updating.
    func checkBinaryVersion() async {
        do {
            let result = try await CLIRunner.run(["--version"])
            if result.success {
                // Parse version from output like "dginf-provider 0.1.0"
                let parts = result.stdout.components(separatedBy: " ")
                if let version = parts.last {
                    // Compare with latest
                    if !latestVersion.isEmpty && isNewer(latestVersion, than: version) {
                        updateAvailable = true
                    }
                }
            }
        } catch {}
    }

    /// Simple semantic version comparison.
    private func isNewer(_ a: String, than b: String) -> Bool {
        let aParts = a.split(separator: ".").compactMap { Int($0) }
        let bParts = b.split(separator: ".").compactMap { Int($0) }

        for i in 0..<max(aParts.count, bParts.count) {
            let aVal = i < aParts.count ? aParts[i] : 0
            let bVal = i < bParts.count ? bParts[i] : 0
            if aVal > bVal { return true }
            if aVal < bVal { return false }
        }
        return false
    }
}
