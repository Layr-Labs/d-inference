import DarkbloomHardwareLoad
import Foundation
import Hummingbird
import NIOCore
import ProviderCore

/// Whole-machine load for the desktop app's chip view. These counters are
/// served on the loopback control API only: never logged, never put in
/// heartbeats and never sent to the coordinator. Other processes appear only
/// as anonymous GPU time inside `provider_share`.
struct DesktopHardware: Sendable {
  static let protocolVersion: Int64 = 1
  static let framesPerStream = 120
  static let live = DesktopHardware(monitor: .live(providerPID: { providerPID() }))

  let monitor: HardwareLoadMonitor

  /// The serving provider process: the daemon while its recorded identity is
  /// still this boot's process, otherwise a live local-only endpoint.
  static func providerPID() -> Int32? {
    if let daemon = DaemonStateFile.read(), daemon.processIdentity?.isCurrent() == true {
      return daemon.pid
    }
    return LocalEndpoint.readLiveInfo()?.pid
  }

  func resource(peakBandwidthGbps: Double?) async -> JSONValue {
    let sample = await monitor.currentSample(waitingUpTo: .milliseconds(1500))
    return .dict([
      "protocol": .int(Self.protocolVersion),
      "topology": Self.json(monitor.topology, peakBandwidthGbps: peakBandwidthGbps),
      "sample": sample.map(Self.json) ?? .null,
    ])
  }

  /// One full sample per frame, so a reconnect never needs to resync deltas.
  func events(lease: DesktopStreamLimiter.Lease) -> Response {
    Response(
      status: .ok, headers: [.contentType: "text/event-stream", .cacheControl: "no-store"],
      body: .init { writer in
        defer { lease.release() }
        var frames = 0
        for await sample in await monitor.samples() {
          let data = try JSONEncoder().encode(Self.json(sample))
          try await writer.write(
            ByteBuffer(string: "event: hardware\ndata: \(String(decoding: data, as: UTF8.self))\n\n"))
          frames += 1
          if frames == Self.framesPerStream { break }
        }
        try await writer.finish(nil)
      })
  }

  static func json(_ topology: HardwareTopology, peakBandwidthGbps: Double?) -> JSONValue {
    .dict([
      "chip": .string(topology.chip), "model": .string(topology.model),
      "cpu": .dict([
        "tiers": .array(
          topology.cpu.tiers.map {
            .dict([
              "level": .int(Int64($0.level)), "name": .string($0.name),
              "kind": .string($0.kind.rawValue), "cores": .int(Int64($0.cores)),
            ])
          }),
        "clusters": .array(
          topology.cpu.clusters.map {
            .dict([
              "id": .int(Int64($0.id)), "kind": .string($0.kind.rawValue),
              "cpus": .array($0.cpus.map { .int(Int64($0)) }),
            ])
          }),
      ]),
      "gpu": .dict([
        "cores": topology.gpu.cores.map { .int(Int64($0)) } ?? .null,
        "groups": .array(topology.gpu.groups.map { .int(Int64($0)) }),
        "max_mhz": .number(topology.gpu.maxMHz),
      ]),
      "ane": .dict(["present": .bool(topology.anePresent)]),
      "memory": .dict([
        "total_gb": .number(gigabytes(topology.memoryTotalBytes)),
        "peak_bandwidth_gbps": .number(peakBandwidthGbps),
      ]),
    ])
  }

  static func json(_ sample: HardwareSample) -> JSONValue {
    .dict([
      "sampled_at": .number(rounded(sample.sampledAt.timeIntervalSince1970, 3)),
      "interval_ms": .int(milliseconds(sample.interval)),
      "cpu": .dict(["load": .array(sample.cpuLoad.map { .number(rounded($0, 3)) })]),
      "gpu": .dict([
        "utilization": .number(rounded(sample.gpu.utilization, 3)),
        "frequency_mhz": .number(rounded(sample.gpu.frequencyMHz, 0)),
        "power_w": .number(rounded(sample.gpu.powerW, 2)),
        "provider_share": .number(rounded(sample.gpu.providerShare, 3)),
        "memory_in_use_gb": .number(rounded(gigabytes(sample.gpu.memoryInUseBytes), 2)),
      ]),
      "ane": .dict([
        "active": .number(rounded(sample.ane.active, 2)),
        "bandwidth_gbps": .number(rounded(sample.ane.bandwidthGBps, 1)),
        "power_w": .number(rounded(sample.ane.powerW, 2)),
      ]),
      "memory": .dict([
        "used_gb": .number(rounded(gigabytes(sample.memory.usedBytes), 2)),
        "wired_gb": .number(rounded(gigabytes(sample.memory.wiredBytes), 2)),
        "pressure": sample.memory.pressure.map { .string($0.rawValue) } ?? .null,
        "bandwidth_gbps": .number(rounded(sample.memory.bandwidthGBps, 1)),
      ]),
      "thermal": .dict(["state": .string(sample.thermal.rawValue)]),
      "provider": .dict(["running": .bool(sample.providerRunning)]),
      "capabilities": .dict(sample.capabilities.mapValues { .string($0.rawValue) }),
    ])
  }

  private static func milliseconds(_ duration: Duration) -> Int64 {
    duration.components.seconds * 1000 + duration.components.attoseconds / 1_000_000_000_000_000
  }

  private static func gigabytes(_ bytes: UInt64?) -> Double? {
    bytes.map { Double($0) / 1_073_741_824 }
  }

  private static func rounded(_ value: Double?, _ places: Int) -> Double? {
    guard let value, value.isFinite else { return value }
    let scale = pow(10, Double(places))
    return (value * scale).rounded() / scale
  }
}

extension DesktopBackend {
  /// Peak unified-memory bandwidth from the cached hardware profile; nil when
  /// the chip is not in the bandwidth table.
  func peakMemoryBandwidthGbps() -> Double? {
    guard let bandwidth = (try? configuration())?.hardware?.memoryBandwidthGbs, bandwidth > 0
    else { return nil }
    return Double(bandwidth)
  }
}
