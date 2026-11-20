import MLX

/// One first-occurrence threadgroup owns each expert's <=3 independent rows.
/// No sort/padding, CPU routing, expert-output reduction, or output permutation.
enum GemmaSmallGatherQMVKernel {
    static let value = MLXFast.metalKernel(
        name: "gemma_small_grouped_gather_qmv_v1",
        inputNames: ["x", "w", "scales", "biases", "ids"], outputNames: ["out"],
        source: #"""
        const uint assignment = threadgroup_position_in_grid.z;
        const uint expert = ids[assignment];
        const uint lane = thread_position_in_threadgroup.x % 32;
        const uint simd = thread_position_in_threadgroup.x / 32;
        const uint out_row = threadgroup_position_in_grid.y * 8 + simd * 4;

        // One uniform threadgroup per first occurrence. Top-k slots are never
        // reordered. A repeated expert within ONE token is a malformed route.
        for (uint prior = 0; prior < assignment; ++prior) {
            if (ids[prior] == expert) { return; }
        }
        uint members[3];
        uint count = 0;
        bool invalid = expert >= E;
        for (uint i = assignment; i < A; ++i) {
            if (ids[i] != expert) { continue; }
            if (count >= 3) { invalid = true; }
            else {
                for (uint j = 0; j < count; ++j) {
                    if (members[j] / 8 == i / 8) { invalid = true; }
                }
                members[count] = i;
            }
            ++count;
        }
        if (invalid) {
            // Fully initialize every affected output without reading a bad
            // expert plane. Qualification/callers require finite output.
            if (lane == 0) {
                for (uint i = assignment; i < A; ++i) {
                    if (ids[i] == expert) {
                        for (uint row = 0; row < 4; ++row) {
                            out[i * N + out_row + row] = T(as_type<float>(0x7fc00000u));
                        }
                    }
                }
            }
            return;
        }

        """# + GemmaSmallQMVArithmetic.body,
        ensureRowContiguous: true)
}
