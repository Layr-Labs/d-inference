### Qwen tensor-parallel ranks wait for each all-sum in the kernel that reads it

The Qwen 3.5 residual step (`ResidualRMSNorm`) now reads its FP32 tensor-parallel
all-sum as a fenced input, as GLM's hyper-connection sites already did, and a
worker turns `MLX_METAL_FENCED_INPUTS` on for every tensor-parallel family whose
kernels read their sums that way (`ClusterResidentModelCatalog.Family
.tensorParallelSumsAreFencedInputs`; a launcher's own value is kept). The kernel
that reads a sum then waits for the CPU itself instead of MLX's separate
fence-wait launch, about 128 of them per verify window of the 27B. MLX consults
the setting only for inputs a kernel declares fenced, so every other launch is
unchanged, and only where the GPU waits changes, never a value. The fused fence
update stays a launcher's choice. Each rank logs the choice (`fenced_sums=` in
`darkbloom-aqv-kernel-v1`) and binds it into the load agreement.
