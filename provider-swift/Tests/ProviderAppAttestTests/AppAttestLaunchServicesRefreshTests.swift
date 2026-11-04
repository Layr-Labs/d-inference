import Foundation
import XCTest
@testable import ProviderAppAttest

/// Stands in for DeviceCheck and LaunchServices: `isSupported` stays false
/// until the app is re-registered `supportedAfterRefreshes` times.
private final class FakeLaunchServices: @unchecked Sendable {
    private let lock = NSLock()
    private var refreshes: [URL] = []
    private let supportedAfterRefreshes: Int?

    init(supportedAfterRefreshes: Int?) { self.supportedAfterRefreshes = supportedAfterRefreshes }

    var refreshed: [URL] { lock.withLock { refreshes } }

    var support: AppAttestSupport {
        AppAttestSupport(
            isSupported: { [self] in
                lock.withLock { supportedAfterRefreshes.map { refreshes.count >= $0 } ?? false }
            },
            refreshRegistration: { [self] url in
                lock.withLock { refreshes.append(url) }
            })
    }
}

private struct NoCallbacks: AppAttestCallbacks {
    func generateKey(_ complete: @escaping @Sendable (Result<String, Error>) -> Void) {}
    func attestKey(_ id: String, hash: Data, complete: @escaping @Sendable (Result<Data, Error>) -> Void) {}
    func generateAssertion(_ id: String, hash: Data, complete: @escaping @Sendable (Result<Data, Error>) -> Void) {}
}

final class AppAttestLaunchServicesRefreshTests: XCTestCase {
    private let app = URL(fileURLWithPath: "/Users/someone/.darkbloom/Darkbloom.app")

    private func service(_ fake: FakeLaunchServices) -> AppleAppAttestService {
        AppleAppAttestService(callbacks: NoCallbacks(), operationTimeout: 1, support: fake.support)
    }

    /// After a self-update swaps `Darkbloom.app` in place, LaunchServices can
    /// still describe the previous bundle and Apple answers unsupported. One
    /// re-registration of the running bundle makes the same answer supported.
    func testUnsupportedAnswerReRegistersTheRunningAppOnceAndAsksAgain() async {
        let fake = FakeLaunchServices(supportedAfterRefreshes: 1)
        let service = service(fake)
        let first = await service.isSupportedRefreshingRegistration(app: app)
        XCTAssertTrue(first, "a stale LaunchServices record must not fail the exchange that refreshes it")
        XCTAssertEqual(fake.refreshed, [app])
        let second = await service.isSupportedRefreshingRegistration(app: app)
        XCTAssertTrue(second)
        XCTAssertEqual(fake.refreshed, [app], "a supported answer never re-registers")
    }

    func testSupportedAnswerNeverTouchesLaunchServices() async {
        let fake = FakeLaunchServices(supportedAfterRefreshes: 0)
        let supported = await service(fake).isSupportedRefreshingRegistration(app: app)
        XCTAssertTrue(supported)
        XCTAssertEqual(fake.refreshed, [])
    }

    /// A Mac that stays unsupported for another reason is re-registered once per
    /// service, not on every coordinator exchange.
    func testPersistentUnsupportedReRegistersOnlyOncePerService() async {
        let fake = FakeLaunchServices(supportedAfterRefreshes: nil)
        let service = service(fake)
        for _ in 0..<3 {
            let supported = await service.isSupportedRefreshingRegistration(app: app)
            XCTAssertFalse(supported)
        }
        XCTAssertEqual(fake.refreshed, [app])
    }
}
