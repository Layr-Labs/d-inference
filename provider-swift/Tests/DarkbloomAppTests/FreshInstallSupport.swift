import Foundation
@testable import DarkbloomApp

extension ReadinessMachineFacts {
    static let freshInstallFixture = ReadinessMachineFacts(
        isAppleSilicon: true,
        physicalMemoryBytes: 32 * 1_073_741_824,
        availableStorageBytes: 100 * 1_073_741_824
    )
}

final class FreshInstallURLRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [URL] = []

    var urls: [URL] { lock.withLock { storage } }

    func append(_ url: URL) {
        lock.withLock { storage.append(url) }
    }
}

@MainActor
func freshInstallEventually(
    timeout: Duration = .seconds(5),
    _ predicate: @MainActor () -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if predicate() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return predicate()
}

/// Disk-backed preferences fake used to simulate app termination/relaunch.
/// It implements the app's exact preference protocol without consulting
/// `UserDefaults.standard` or the host's Darkbloom defaults domain.
@MainActor
final class FreshInstallPreferences: AppFlowPreferenceStoring {
    private struct Payload: Codable {
        var completed = false
        var draft: OnboardingDraft?
    }

    private let fileURL: URL

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    var hasCompletedNetworkOnboarding: Bool {
        get { read().completed }
        set {
            var payload = read()
            payload.completed = newValue
            write(payload)
        }
    }

    var onboardingDraft: OnboardingDraft? {
        get { read().draft }
        set {
            var payload = read()
            payload.draft = newValue
            write(payload)
        }
    }

    private func read() -> Payload {
        guard let data = try? Data(contentsOf: fileURL),
              let payload = try? JSONDecoder().decode(Payload.self, from: data)
        else { return Payload() }
        return payload
    }

    private func write(_ payload: Payload) {
        do {
            let data = try JSONEncoder().encode(payload)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            preconditionFailure("Fresh-install preferences write failed: \(error)")
        }
    }
}
