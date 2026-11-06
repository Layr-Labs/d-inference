import MLX

/// Shares the production allocator/fragmentation projection without copying
/// its arithmetic into the experimental resident owner.
@_spi(Cluster) public func cbv2ClusterAuxiliaryAllocationBytes(
    tokens: Int, policy: AllocationFootprintPolicy, specs: [CBv2AuxiliaryAllocationSpec]
) -> Int? {
    guard !specs.isEmpty,
          let projection = CBv2AuxiliaryAllocationProjection(policy: policy, buffers: specs) else { return nil }
    return projection.bytes(forTokens: tokens)
}
