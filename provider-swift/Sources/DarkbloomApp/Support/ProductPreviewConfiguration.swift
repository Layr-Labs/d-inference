import Foundation

struct ProductPreviewConfiguration: Sendable {
    let destination: ProductDestination
    let providerScenario: ProviderPreviewScenario
    let modelFixture: ModelLibraryFixture
    let diagnosticsFixture: DiagnosticsFixture
    let contributionsFixture: ContributionsFixture
    let localAPIFixture: LocalAPIFixture
    let myMacsFixture: MyMacsFixture
    let availabilityFixture: AvailabilityFixture
    let chatFixture: PreviewChatFixture

    static var current: Self? {
        #if DEBUG
        resolve(environment: ProcessInfo.processInfo.environment)
        #else
        nil
        #endif
    }

    static func resolve(environment: [String: String]) -> Self? {
        guard let rawDestination = environment["DARKBLOOM_PREVIEW_PRODUCT_DESTINATION"],
              let destination = ProductDestination(rawValue: rawDestination.lowercased())
        else {
            return nil
        }

        let availabilityFixture = environment["DARKBLOOM_PREVIEW_AVAILABILITY_FIXTURE"]
            .flatMap { AvailabilityFixture(rawValue: $0.lowercased()) }
            ?? (destination == .availability ? .scheduledActive : .always)
        let scenario = environment["DARKBLOOM_PREVIEW_PROVIDER_SCENARIO"]
            .flatMap { ProviderPreviewScenario(rawValue: $0.lowercased()) }
            ?? defaultProviderScenario(for: availabilityFixture)
        let modelFixture = environment["DARKBLOOM_PREVIEW_MODEL_FIXTURE"]
            .flatMap { ModelLibraryFixture(rawValue: $0) } ?? .ready
        let diagnosticsFixture = environment["DARKBLOOM_PREVIEW_DIAGNOSTICS_FIXTURE"]
            .flatMap { DiagnosticsFixture(rawValue: $0) } ?? .healthy
        let contributionsFixture = environment["DARKBLOOM_PREVIEW_CONTRIBUTIONS_FIXTURE"]
            .flatMap { ContributionsFixture(rawValue: $0) } ?? .active
        let localAPIFixture = environment["DARKBLOOM_PREVIEW_LOCAL_API_FIXTURE"]
            .flatMap { LocalAPIFixture(rawValue: $0) }
            ?? defaultLocalAPIFixture(for: scenario)
        let myMacsFixture = environment["DARKBLOOM_PREVIEW_MY_MACS_FIXTURE"]
            .flatMap { MyMacsFixture(rawValue: $0) } ?? .ready
        let chatFixture = environment["DARKBLOOM_PREVIEW_CHAT_FIXTURE"]
            .flatMap { PreviewChatFixture(rawValue: $0.lowercased()) } ?? .empty

        return Self(
            destination: destination,
            providerScenario: scenario,
            modelFixture: modelFixture,
            diagnosticsFixture: diagnosticsFixture,
            contributionsFixture: contributionsFixture,
            localAPIFixture: localAPIFixture,
            myMacsFixture: myMacsFixture,
            availabilityFixture: availabilityFixture,
            chatFixture: chatFixture
        )
    }

    private static func defaultLocalAPIFixture(
        for scenario: ProviderPreviewScenario
    ) -> LocalAPIFixture {
        switch scenario {
        case .paused, .pausedScheduled, .scheduledOff:
            .stopped
        case .stale:
            .unreachable
        case .online, .serving, .scheduledActive, .attention:
            .active
        }
    }

    private static func defaultProviderScenario(
        for fixture: AvailabilityFixture
    ) -> ProviderPreviewScenario {
        switch fixture {
        case .scheduledOff: .scheduledOff
        case .pausedScheduled: .pausedScheduled
        case .scheduledActive: .scheduledActive
        case .serving: .serving
        case .stale: .stale
        case .malformed: .attention
        case .always, .loading, .saveFailure: .online
        }
    }
}
