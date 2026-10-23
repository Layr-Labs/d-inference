import Foundation
import IOKit

/// Reads `HardwareTopology` from sysctl and the I/O Registry. Public APIs only.
public enum TopologyProbe {
    public static func read() -> HardwareTopology {
        let cpu = CPUTopologyResolver.resolve(levels: perfLevels(), nodes: deviceTreeCPUs())
        let gpuDescription = gpuConfiguration()
        let gpuTable = GPUFrequencyTable.read()
        return HardwareTopology(
            chip: SystemControl.string("machdep.cpu.brand_string") ?? "Apple Silicon",
            model: SystemControl.string("hw.model") ?? "Mac",
            cpu: cpu,
            gpu: HardwareTopology.GPU(
                cores: gpuDescription.cores, groups: gpuDescription.groups, maxMHz: gpuTable.max()),
            anePresent: RegistryProperty.matchingService(ANEPowerProbe.serviceClass).map {
                IOObjectRelease($0)
                return true
            } ?? false,
            memoryTotalBytes: UInt64(max(SystemControl.integer("hw.memsize") ?? 0, 0)))
    }

    static func perfLevels() -> [PerfLevel] {
        let count = max(SystemControl.integer("hw.nperflevels") ?? 0, 0)
        let levels = (0..<count).map { index in
            PerfLevel(
                index: index,
                name: SystemControl.string("hw.perflevel\(index).name") ?? "",
                logicalCPUs: SystemControl.integer("hw.perflevel\(index).logicalcpu") ?? 0,
                cpusPerL2: SystemControl.integer("hw.perflevel\(index).cpusperl2") ?? 0)
        }
        guard levels.isEmpty || levels.allSatisfy({ $0.logicalCPUs == 0 }) else { return levels }
        let total = SystemControl.integer("hw.logicalcpu") ?? ProcessInfo.processInfo.processorCount
        return [PerfLevel(index: 0, name: "Performance", logicalCPUs: total, cpusPerL2: total)]
    }

    static func deviceTreeCPUs() -> [DeviceTreeCPU] {
        let cpus = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/cpus")
        guard cpus != IO_OBJECT_NULL else { return [] }
        defer { IOObjectRelease(cpus) }
        var nodes: [DeviceTreeCPU] = []
        _ = RegistryProperty.forEachChild(of: cpus, plane: kIODeviceTreePlane) { entry in
            guard let name = RegistryProperty.name(entry), name.hasPrefix("cpu"),
                let nameIndex = Int(name.dropFirst(3))
            else { return }
            nodes.append(
                DeviceTreeCPU(
                    id: RegistryProperty.integer(entry, "logical-cpu-id") ?? nameIndex,
                    cluster: RegistryProperty.integer(entry, "logical-cluster-id")
                        ?? RegistryProperty.integer(entry, "cluster-id") ?? 0,
                    clusterType: RegistryProperty.string(entry, "cluster-type") ?? ""))
        }
        return nodes
    }

    private static func gpuConfiguration() -> (cores: Int?, groups: [Int]) {
        guard let accelerator = RegistryProperty.matchingService("AGXAccelerator") else {
            return (nil, [])
        }
        defer { IOObjectRelease(accelerator) }
        let cores = RegistryProperty.integer(accelerator, "gpu-core-count")
        let configuration = RegistryProperty.value(accelerator, "GPUConfigurationVariable")
            as? [String: Any]
        let masks = (configuration?["core_mask_list"] as? [NSNumber])?.map(\.intValue) ?? []
        return (cores, gpuCoreGroups(masks: masks, cores: cores))
    }

    /// Enabled cores per mGPU from the driver's per-partition core masks. Falls
    /// back to one group when the masks are missing or disagree with the core count.
    static func gpuCoreGroups(masks: [Int], cores: Int?) -> [Int] {
        let groups = masks.map { $0.nonzeroBitCount }.filter { $0 > 0 }
        if !groups.isEmpty, cores == nil || groups.reduce(0, +) == cores { return groups }
        return cores.map { [$0] } ?? []
    }
}
