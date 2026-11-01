import DarkbloomHardwareLoad
import Foundation
import Hummingbird
import NIOCore
import ProviderCore
import Testing

@testable import darkbloom

/// Emits a fixed sample every few milliseconds while started.
private final class FastEngine: HardwareSamplingEngine, @unchecked Sendable {
  private let lock = NSLock()
  private var ticker: Task<Void, Never>?

  func start(emit: @escaping @Sendable (HardwareSample) -> Void) {
    lock.withLock {
      guard ticker == nil else { return }
      ticker = Task {
        while !Task.isCancelled {
          try? await Task.sleep(for: .milliseconds(2))
          emit(
            HardwareSample(
              sampledAt: Date(), interval: .milliseconds(1001), cpuLoad: [0.25, 1],
              gpu: .init(utilization: 0.99, providerShare: 0.5, memoryInUseBytes: 2 << 30),
              ane: .init(active: 0), memory: .init(usedBytes: 64 << 30, pressure: .normal),
              thermal: .fair, providerRunning: true,
              capabilities: ["gpu_power": .pending, "memory_bandwidth": .estimated]))
        }
      }
    }
  }

  func stop() {
    lock.withLock {
      ticker?.cancel()
      ticker = nil
    }
  }
}

/// The desktop API on a real loopback socket: its auth requires a
/// `127.0.0.1` authority, which Hummingbird's in-memory tester cannot send.
@Suite(.serialized) struct DesktopHardwareRouteTests {
  private let token = "fixture-token"

  private func withServer(_ body: @Sendable (URL) async throws -> Void) async throws {
    let topology = HardwareTopology(
      chip: "Apple M4 Max", model: "Mac16,5",
      cpu: .init(
        tiers: [
          .init(level: 0, name: "Performance", kind: .performance, cores: 1),
          .init(level: 1, name: "Efficiency", kind: .efficiency, cores: 1),
        ],
        clusters: [
          .init(id: 0, kind: .efficiency, cpus: [0]), .init(id: 1, kind: .performance, cpus: [1]),
        ]),
      gpu: .init(cores: 40, groups: [10, 10, 10, 10], maxMHz: 1578), anePresent: true,
      memoryTotalBytes: 128 << 30)
    let (ports, port) = AsyncStream.makeStream(of: Int.self)
    let app = Application(
      responder: DesktopHTTP(
        backend: DesktopBackend(configPath: "/nonexistent-desktop-test-config"), token: token,
        hardware: DesktopHardware(
          monitor: HardwareLoadMonitor(topology: topology, engine: FastEngine()))),
      configuration: .init(address: .hostname("127.0.0.1", port: 0)),
      onServerRunning: { channel in
        port.yield(channel.localAddress?.port ?? 0)
        port.finish()
      })
    let server = Task { try await app.runService(gracefulShutdownSignals: []) }
    defer { server.cancel() }
    var iterator = ports.makeAsyncIterator()
    let bound = try #require(await iterator.next())
    try await body(URL(string: "http://127.0.0.1:\(bound)")!)
  }

  private func get(
    _ base: URL, _ path: String, authorized: Bool = true, origin: String? = nil
  ) async throws -> (Data, HTTPURLResponse) {
    var request = URLRequest(url: base.appendingPathComponent(path))
    if authorized { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
    if let origin { request.setValue(origin, forHTTPHeaderField: "Origin") }
    let (data, response) = try await URLSession.shared.data(for: request)
    return (data, try #require(response as? HTTPURLResponse))
  }

  @Test(arguments: ["control/v1/hardware", "control/v1/hardware/events"])
  func routesRequireTheBearerTokenAndNoBrowserOrigin(path: String) async throws {
    try await withServer { base in
      let anonymous = try await get(base, path, authorized: false).1
      let browser = try await get(base, path, origin: "https://example.com").1
      #expect(anonymous.statusCode == 401)
      #expect(browser.statusCode == 401)
    }
  }

  @Test func snapshotCarriesTopologyAndAFullSample() async throws {
    try await withServer { base in
      let (data, response) = try await get(base, "control/v1/hardware")
      #expect(response.statusCode == 200)
      let body = try JSONDecoder().decode(JSONValue.self, from: data)
      #expect(body.field("protocol") == .int(1))
      let topology = body.field("topology")
      #expect(topology.field("cpu").field("clusters").values.count == 2)
      #expect(
        topology.field("gpu").field("groups") == .array([.int(10), .int(10), .int(10), .int(10)]))
      #expect(topology.field("memory").field("total_gb").number == 128)
      let sample = body.field("sample")
      #expect(sample.field("cpu").field("load").values.compactMap(\.number) == [0.25, 1])
      #expect(sample.field("gpu").field("utilization").number == 0.99)
      #expect(sample.field("gpu").field("provider_share").number == 0.5)
      #expect(sample.field("gpu").field("memory_in_use_gb").number == 2)
      #expect(sample.field("provider").field("running") == .bool(true))
      #expect(sample.field("thermal").field("state") == .string("fair"))
      #expect(sample.field("interval_ms") == .int(1001))
      #expect(sample.field("capabilities").field("gpu_power") == .string("pending"))
      // Unknown values are explicit nulls: present in the JSON, never omitted or zero.
      let raw = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
      let gpu = try #require((raw["sample"] as? [String: Any])?["gpu"] as? [String: Any])
      #expect(gpu["power_w"] is NSNull)
      #expect(gpu["frequency_mhz"] is NSNull)
      let memory = try #require((raw["sample"] as? [String: Any])?["memory"] as? [String: Any])
      #expect(memory["bandwidth_gbps"] is NSNull)
    }
  }

  @Test func eventStreamSendsOneHundredTwentyFullSampleFrames() async throws {
    try await withServer { base in
      let (data, response) = try await get(base, "control/v1/hardware/events")
      #expect(response.statusCode == 200)
      #expect(response.value(forHTTPHeaderField: "Content-Type") == "text/event-stream")
      let frames = String(decoding: data, as: UTF8.self).components(separatedBy: "\n\n").filter {
        !$0.isEmpty
      }
      #expect(frames.count == DesktopHardware.framesPerStream)
      for frame in frames {
        let lines = frame.split(separator: "\n", maxSplits: 1)
        #expect(lines.first == "event: hardware")
        let payload = try #require(lines.last?.dropFirst("data: ".count))
        let sample = try JSONDecoder().decode(JSONValue.self, from: Data(payload.utf8))
        #expect(sample.field("cpu").field("load").values.count == 2)
        #expect(sample.field("topology") == .null)
      }
    }
  }
}
