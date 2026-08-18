import Foundation

enum LocalAPIFixtures {
    static let referenceDate = Date(timeIntervalSince1970: 1_784_381_400)
    static let sampleModelIDs = ["gpt-oss-20b", "gemma-4-26b-qat-4bit"]

    static func make(_ fixture: LocalAPIFixture) -> LocalAPIState {
        switch fixture {
        case .active:
            return .running(endpoint(mode: .unified))

        case .directOnly:
            return .running(endpoint(mode: .directOnly))

        case .starting:
            return .starting(
                message: "Waiting for the local endpoint to confirm that its port is listening."
            )

        case .stopped:
            return .stopped(
                message: "No live local discovery record was found."
            )

        case .authDisabled:
            var endpoint = endpoint(mode: .unified)
            endpoint.apiKey = nil
            return .running(endpoint)

        case .networkExposed:
            var endpoint = endpoint(mode: .unified)
            endpoint.host = "0.0.0.0"
            return .running(endpoint)

        case .noCompatibleModels:
            var endpoint = endpoint(mode: .unified)
            endpoint.modelCatalog = .available([])
            return .running(endpoint)

        case .modelCatalogUnavailable:
            var endpoint = endpoint(mode: .unified)
            endpoint.modelCatalog = .failed
            return .running(endpoint)

        case .healthChecking:
            var endpoint = endpoint(mode: .unified)
            endpoint.health = .checking
            return .running(endpoint)

        case .portCollision:
            return .unavailable(
                message: "Port 8000 is already in use, so Darkbloom could not bind the local endpoint."
            )

        case .tokenUnavailable:
            return .unavailable(
                message: "Darkbloom could not create the local API token. Check the permissions for ~/.darkbloom and try again."
            )

        case .unreachable:
            var endpoint = endpoint(mode: .unified)
            endpoint.health = .unreachable
            return .running(endpoint)
        }
    }

    private static func endpoint(mode: LocalAPIMode) -> LocalAPIEndpointSnapshot {
        LocalAPIEndpointSnapshot(
            baseURL: URL(string: "http://127.0.0.1:8000/v1")!,
            host: "127.0.0.1",
            port: 8000,
            apiKey: "dk-local-preview-only-not-a-secret",
            pid: 7_304,
            version: "0.7.9",
            updatedAt: referenceDate,
            mode: mode,
            health: .reachable,
            modelCatalog: .available(sampleModelIDs)
        )
    }
}
