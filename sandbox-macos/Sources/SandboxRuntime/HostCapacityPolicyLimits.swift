import Foundation

extension SandboxCapacityPolicy {
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                maximumRunningSandboxes: container.decode(
                    Int.self,
                    forKey: .maximumRunningSandboxes
                ),
                maximumReservedCPUCount: container.decode(
                    UInt16.self,
                    forKey: .maximumReservedCPUCount
                ),
                maximumReservedMemoryBytes: container.decode(
                    UInt64.self,
                    forKey: .maximumReservedMemoryBytes
                ),
                maximumReservedGrowthBytes: container.decode(
                    UInt64.self,
                    forKey: .maximumReservedGrowthBytes
                ),
                storageHeadroomBytes: container.decode(
                    UInt64.self,
                    forKey: .storageHeadroomBytes
                ),
                maximumLeaseDurationSeconds: container.decode(
                    TimeInterval.self,
                    forKey: .maximumLeaseDurationSeconds
                )
            )
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .maximumRunningSandboxes,
                in: container,
                debugDescription: "invalid sandbox capacity policy"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(
            maximumRunningSandboxes,
            forKey: .maximumRunningSandboxes
        )
        try container.encode(
            maximumReservedCPUCount,
            forKey: .maximumReservedCPUCount
        )
        try container.encode(
            maximumReservedMemoryBytes,
            forKey: .maximumReservedMemoryBytes
        )
        try container.encode(
            maximumReservedGrowthBytes,
            forKey: .maximumReservedGrowthBytes
        )
        try container.encode(
            storageHeadroomBytes,
            forKey: .storageHeadroomBytes
        )
        try container.encode(
            maximumLeaseDurationSeconds,
            forKey: .maximumLeaseDurationSeconds
        )
    }

    func widensCapacity(comparedTo current: Self) -> Bool {
        maximumRunningSandboxes > current.maximumRunningSandboxes
            || maximumReservedCPUCount
                > current.maximumReservedCPUCount
            || maximumReservedMemoryBytes
                > current.maximumReservedMemoryBytes
            || maximumReservedGrowthBytes
                > current.maximumReservedGrowthBytes
            || storageHeadroomBytes < current.storageHeadroomBytes
            || maximumLeaseDurationSeconds
                > current.maximumLeaseDurationSeconds
    }

    func accommodatesResourceCommitments(
        _ leases: [SandboxCapacityLease]
    ) -> Bool {
        guard leases.count <= maximumRunningSandboxes else {
            return false
        }
        var cpuCount: UInt16 = 0
        var memoryBytes: UInt64 = 0
        var growthBytes: UInt64 = 0
        for lease in leases {
            let (newCPUCount, cpuOverflow) = cpuCount.addingReportingOverflow(
                lease.cpuCount
            )
            let (newMemoryBytes, memoryOverflow) =
                memoryBytes.addingReportingOverflow(lease.memoryBytes)
            let (newGrowthBytes, growthOverflow) =
                growthBytes.addingReportingOverflow(lease.reservedGrowthBytes)
            guard !cpuOverflow,
                  !memoryOverflow,
                  !growthOverflow
            else {
                return false
            }
            cpuCount = newCPUCount
            memoryBytes = newMemoryBytes
            growthBytes = newGrowthBytes
        }
        return cpuCount <= maximumReservedCPUCount
            && memoryBytes <= maximumReservedMemoryBytes
            && growthBytes <= maximumReservedGrowthBytes
    }

    func accommodates(
        _ leases: [SandboxCapacityLease],
        at date: Date
    ) -> Bool {
        guard accommodatesResourceCommitments(leases) else {
            return false
        }
        return leases.allSatisfy { lease in
            let remaining = lease.expiresAt.timeIntervalSince(date)
            return remaining.isFinite
                && remaining <= maximumLeaseDurationSeconds
        }
    }

    private enum CodingKeys: String, CodingKey {
        case maximumRunningSandboxes
        case maximumReservedCPUCount
        case maximumReservedMemoryBytes
        case maximumReservedGrowthBytes
        case storageHeadroomBytes
        case maximumLeaseDurationSeconds
    }
}
