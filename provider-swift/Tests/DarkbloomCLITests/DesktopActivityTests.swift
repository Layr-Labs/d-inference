import Foundation
import ProviderCore
import Testing
@testable import darkbloom

struct DesktopActivityTests {
  @Test func activityPreservesUnknownAndExpiresOldCapacity() throws {
    let model = DaemonState.ModelActivity(model: "model", state: "running", running: 7, waiting: 2)
    let capacity = DaemonState.Capacity(totalMemoryGb: 64, gpuMemoryActiveGb: 20,
      modelActivity: [model], activityObservedAt: 100)
    let value = DesktopBackend.modelActivity(capacity, fresh: true, now: 102)
    #expect(value.values.first?.field("running").number == 7)
    #expect(value.values.first?.field("waiting").number == 2)
    #expect(DesktopBackend.modelActivity(capacity, fresh: true, now: 111) == .null)
    #expect(DesktopBackend.modelActivity(capacity, fresh: false, now: 102) == .null)
    let legacy = try JSONDecoder().decode(DaemonState.Capacity.self,
      from: Data(#"{"totalMemoryGb":64,"gpuMemoryActiveGb":20}"#.utf8))
    #expect(legacy.modelActivity == nil)
    #expect(DesktopBackend.modelActivity(legacy, fresh: true, now: 102) == .null)
    #expect(try JSONDecoder().decode(DaemonState.Capacity.self, from: JSONEncoder().encode(capacity)) == capacity)
  }

  @Test func accountRevisionChangesWithoutExposingTheCredential() {
    var session = DesktopAccountSession()
    let initial = session.observe(nil)
    let linked = session.observe("test-only-token-a")
    #expect(initial != linked)
    #expect(linked != "test-only-token-a")
    #expect(session.observe("test-only-token-a") == linked)
    #expect(session.observe("test-only-token-b") != linked)
    #expect(session.observe(nil) != initial)
  }
}
