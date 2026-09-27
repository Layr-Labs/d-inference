// Copyright © 2026 Eigen Labs.

import Foundation
import MLXLMCommon

/// Scalar copy of one native queue capture. It retains no pool or MLX arrays.
struct PagedStorageTelemetryCapture {
    let sourceGeneration: UUID
    let capturedUptimeNanoseconds: UInt64
    var value: PagedStorageTelemetry

    init(sourceGeneration: UUID, capturedUptimeNanoseconds: UInt64,
         value: PagedStorageTelemetry) {
        self.sourceGeneration = sourceGeneration
        self.capturedUptimeNanoseconds = capturedUptimeNanoseconds
        self.value = value
    }

    init?(_ source: PagedKVStorageSnapshot) {
        let bytes = [source.grantBytes, source.committedBytes, source.reservedPageBytes,
                     source.livePageBytes, source.poisonBytes, source.slackBytes,
                     source.allocatorPaddingBytes, source.lastAllocationAllowanceBytes]
        guard bytes.allSatisfy({ $0 >= 0 }), source.segmentCount >= 0,
              source.addressPages >= 0,
              source.nominalKVBytes.map({ $0 >= 0 }) ?? true,
              source.physicalFloorOverheadBytes.map({ $0 >= 0 }) ?? true
        else { return nil }
        let byteLimit: UInt64 = 1 << 50
        func gauge(_ value: Int) -> UInt64 { min(UInt64(value), byteLimit) }
        var value = PagedStorageTelemetry()
        value.sampleSeq = source.captureSequence
        value.grantBytes = gauge(source.grantBytes)
        value.committedBytes = gauge(source.committedBytes)
        value.reservedPageBytes = gauge(source.reservedPageBytes)
        value.livePageBytes = gauge(source.livePageBytes)
        value.poisonBytes = gauge(source.poisonBytes)
        value.slackBytes = gauge(source.slackBytes)
        value.allocatorPaddingBytes = gauge(source.allocatorPaddingBytes)
        value.lastAllocationAllowanceBytes = gauge(source.lastAllocationAllowanceBytes)
        value.overGrantBytes = gauge(source.overGrantBytes)
        value.segmentCount = min(UInt64(source.segmentCount), 1 << 32)
        value.addressPages = min(UInt64(source.addressPages), 1 << 32)
        value.nominalKVBytes = source.nominalKVBytes.map(gauge)
        value.physicalFloorOverheadBytes = source.physicalFloorOverheadBytes.map(gauge)
        value.allocationFailuresTotal = min(source.allocationFailures, 1 << 60)
        value.admissionRefusalsTotal = min(source.admissionRefusals, 1 << 60)
        value.grantRefusalsTotal = min(source.grantRefusals, 1 << 60)
        value.grantEpochRetriesTotal = min(source.grantEpochRetries, 1 << 60)
        self.init(sourceGeneration: source.generation,
                  capturedUptimeNanoseconds: source.capturedUptimeNanoseconds, value: value)
    }
}

/// Actor-owned adapter. Polling cannot mint a native capture or renew its age.
struct PagedStorageTelemetryAdapter {
    private final class Generations: @unchecked Sendable {
        static let shared = Generations()
        private let lock = NSLock()
        // A process nonce avoids reusing the same small generation after a
        // provider restart; keep numeric identifiers exactly representable in JS.
        private var value = UInt64.random(in: 1..<(1 << 52))
        func next() -> UInt64? {
            lock.withLock {
                guard value < (1 << 53) - 1 else { return nil }
                value += 1
                return value
            }
        }
    }

    private var latest: PagedStorageTelemetryCapture?

    mutating func snapshot(
        _ capture: PagedStorageTelemetryCapture?,
        nowUptimeNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds
    ) -> PagedStorageTelemetry? {
        guard var capture else { return nil }
        guard capture.value.sampleSeq > 0,
              capture.capturedUptimeNanoseconds <= nowUptimeNanoseconds else { return nil }
        if let previous = latest, previous.sourceGeneration == capture.sourceGeneration {
            if capture.value.sampleSeq > previous.value.sampleSeq {
                // A later sequence cannot carry an earlier native clock.
                if capture.capturedUptimeNanoseconds >= previous.capturedUptimeNanoseconds {
                    capture.value.generation = previous.value.generation
                    latest = capture
                }
            }
        } else {
            guard let generation = Generations.shared.next() else { return nil }
            capture.value.generation = generation
            latest = capture
        }
        guard var sample = latest else { return nil }
        let elapsed = nowUptimeNanoseconds >= sample.capturedUptimeNanoseconds
            ? nowUptimeNanoseconds - sample.capturedUptimeNanoseconds : 0
        sample.value.sampleAgeMs = min(elapsed / 1_000_000, 1 << 60)
        return sample.value
    }
}
