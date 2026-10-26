import Foundation
import IOKit

/// Accumulated GPU time of one Metal client connection (`AGXDeviceUserClient`).
struct GPUClientTime: Equatable {
    let entryID: UInt64
    let pid: Int32
    let nanoseconds: UInt64
}

/// The provider's fraction of all GPU time consumed since the previous update.
///
/// Deltas are tracked per client connection so a process opening or closing a
/// Metal device cannot make its total jump backwards.
struct ProviderGPUShare {
    private var previous: [UInt64: UInt64]?

    /// nil until a baseline exists; 0 when the provider is not running or the
    /// GPU did no work.
    mutating func update(clients: [GPUClientTime], providerPID: Int32?) -> Double? {
        defer { previous = Dictionary(clients.map { ($0.entryID, $0.nanoseconds) }) { $1 } }
        guard let previous else { return nil }
        var total: UInt64 = 0
        var provider: UInt64 = 0
        for client in clients {
            // A connection absent from the previous scan opened after it, so all its time is new.
            let before = previous[client.entryID] ?? 0
            let delta = client.nanoseconds >= before ? client.nanoseconds - before : 0
            total &+= delta
            if client.pid == providerPID { provider &+= delta }
        }
        guard providerPID != nil, total > 0 else { return 0 }
        return min(1, Double(provider) / Double(total))
    }
}

/// Reads per-connection GPU time from the AGX accelerator's user clients.
/// Only pids and times are read; client process names are never collected.
enum GPUClientScanner {
    static func scan() -> [GPUClientTime]? {
        guard let accelerator = RegistryProperty.matchingService("AGXAccelerator") else { return nil }
        defer { IOObjectRelease(accelerator) }
        var clients: [GPUClientTime] = []
        let listed = RegistryProperty.forEachChild(of: accelerator, plane: kIOServicePlane) { child in
            guard
                let pid = (RegistryProperty.value(child, "IOUserClientCreator") as? String)
                    .flatMap(creatorPID),
                let nanoseconds = accumulatedNanoseconds(RegistryProperty.value(child, "AppUsage"))
            else { return }
            var entryID: UInt64 = 0
            guard IORegistryEntryGetRegistryEntryID(child, &entryID) == KERN_SUCCESS else { return }
            clients.append(GPUClientTime(entryID: entryID, pid: pid, nanoseconds: nanoseconds))
        }
        return listed ? clients : nil
    }

    /// `IOUserClientCreator` reads "pid 123, ProcessName".
    static func creatorPID(_ creator: String) -> Int32? {
        guard creator.hasPrefix("pid "), let comma = creator.firstIndex(of: ",") else { return nil }
        return Int32(creator[creator.index(creator.startIndex, offsetBy: 4)..<comma])
    }

    /// `AppUsage` is an array of per-API dictionaries carrying `accumulatedGPUTime` (ns).
    static func accumulatedNanoseconds(_ appUsage: Any?) -> UInt64? {
        guard let entries = appUsage as? [[String: Any]] else { return nil }
        return entries.compactMap { ($0["accumulatedGPUTime"] as? NSNumber)?.uint64Value }
            .reduce(0, &+)
    }
}
