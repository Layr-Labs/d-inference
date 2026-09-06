import Foundation

struct AppleSiliconFacts: Equatable, Sendable {
    let generation: Int
    let introductionYear: Int

    static func resolve(chipName: String) -> Self? {
        let normalized = chipName.uppercased()

        if normalized.contains("M4") {
            return Self(generation: 4, introductionYear: 2024)
        }
        if normalized.contains("M3") {
            return Self(generation: 3, introductionYear: 2023)
        }
        if normalized.contains("M2") {
            return Self(generation: 2, introductionYear: 2022)
        }
        if normalized.contains("M1") {
            return Self(generation: 1, introductionYear: 2020)
        }
        return nil
    }
}

enum MachineFactsFormatter {
    static func memory(_ bytes: UInt64?) -> String {
        guard let bytes else { return "—" }
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
    }

    static func storage(_ bytes: UInt64?) -> String {
        guard let bytes else { return "—" }
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .decimal)
    }

    static func storageSummary(total: UInt64?, available: UInt64?) -> String {
        guard total != nil || available != nil else { return "—" }
        if let available {
            return "\(storage(available)) free"
        }
        return storage(total)
    }
}

extension MachineIdentity {
    var siliconFacts: AppleSiliconFacts? {
        AppleSiliconFacts.resolve(chipName: chipName)
    }

    var inferenceFunFact: String {
        if let physicalMemoryBytes, physicalMemoryBytes >= 64 * 1_024 * 1_024 * 1_024 {
            return "Unified memory lets the CPU and GPU share large models without copying them between separate memory pools."
        }

        switch formFactor {
        case .macBook:
            return "A battery-backed node can ride through brief power interruptions without dropping its local model."
        case .macMini:
            return "Mac mini turns a remarkably small footprint into a quiet, always-on inference node."
        case .macStudio, .macPro:
            return "This form factor is built for sustained workloads, where cooling matters as much as peak speed."
        case .iMac:
            return "The entire inference node lives behind the display—compute, memory, and encrypted model state."
        case .mac:
            return "Apple silicon keeps model weights and compute in one unified memory architecture."
        }
    }
}
