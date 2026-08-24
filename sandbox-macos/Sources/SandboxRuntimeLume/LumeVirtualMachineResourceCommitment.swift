import SandboxRuntime

enum LumeVirtualMachineResourceCommitment {
    static func requireMatch(
        observed: SandboxVirtualMachineRecord,
        ownership: LumeVirtualMachineOwnership.ResourceCommitment,
        lease: SandboxCapacityLease?
    ) throws {
        guard observed.name == ownership.name,
              observed.cpuCount == ownership.cpuCount,
              observed.memoryBytes == ownership.memoryBytes,
              observed.diskBytes == ownership.diskBytes,
              lease.map({ lease in
                  lease.virtualMachineName == ownership.name
                      && lease.cpuCount == ownership.cpuCount
                      && lease.memoryBytes == ownership.memoryBytes
                      && lease.bootDiskBytes == ownership.diskBytes
              }) ?? true
        else {
            if lease != nil {
                throw SandboxCapacityError.leaseResourceMismatch
            }
            throw SandboxRuntimeError.unsupported(
                "VM \(observed.name) resources do not match its Darkbloom ownership commitment"
            )
        }
    }
}
