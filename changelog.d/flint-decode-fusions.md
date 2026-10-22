### Flint decode fusions

- Pin the SDK with exact Flint decode fusions (fused q/k/v and gate/up projections, fused routed gate/up banks, a single MoE combine-and-residual kernel and compiled router steps): about 40% fewer GPU dispatches per decode token with byte-identical outputs.
