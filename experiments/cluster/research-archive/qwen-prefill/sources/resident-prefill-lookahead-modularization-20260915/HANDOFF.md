# Lookahead producer source split

2026-09-15. This private two-file delta applies after the frozen lookahead overlay with manifest SHA `aa91244615528a5534b811d53368cbb6a1b30903dee18d7800027c79a2f391ca`. No frozen source, main file, timing controller, native binary or build cache was changed.

`QwenGenerationLookaheadProducer` moves from `QwenLayerStageGenerationDriver.swift` into `QwenGenerationLookaheadProducer.swift`. Its top-level class changes from `private final` to module-internal `final`, allowing the existing driver to construct it across files. Every class-body byte, including private state and helper access, remains identical. The remaining driver bytes are identical. Rejoining the files and restoring the original visibility recreates the complete original driver exactly.

The driver decreases from 347 to 279 lines; the producer file is 71 lines including imports. `integration.json` lists the two changes plus all seven unchanged lookahead runtime members. `runtime.patch` applies only this split, after the original overlay. SwiftPM discovers the additional source file automatically. There is no public API, algorithm, policy, arithmetic, gate, buffer lifetime, ACK order, cancellation or resource change.

Validation passed:

- Exact full-driver reconstruction and class/remaining-driver byte comparisons.
- The frozen overlay's 32 static source-preservation checks, with the shortened driver substituted and output redirected to this new directory.
- Both proposed Swift files syntax-parse.
- Unchanged Foundation policy fixture: six groups.
- Unchanged comparison fixture: three original serial byte comparisons and three opt-in agreement/result cases.
- Frozen overlay members and all checked dependency pins unchanged through the checks.

The final CPU/static receipt is `records/checks.json`, SHA `4eaf99997efcda2757dd8a67050abbecb162da9c8dd7ab0bbc2a5fd365d582d6`. The tests do not compile or execute the MLX producer; native compilation after integration remains root-owned. The qualified serial/lookahead behavior supplies the source baseline, not a qualification of a newly built binary.

During precheck, root's separate capability promotion moved the exact existing SHA helper from `QwenModelConstruction.swift` to `ClusterMetadataHashing.swift`. The historical dependency pin correctly refused before tests. `records/dependency-transition.json` records both hashes and the reviewed capability manifest. The source checker now locates the new helper and still requires its body to equal the frozen extracted helper exactly. No lookahead source or test body changed for that dependency move.

The remaining driver coordinates one request and keeps its three small source/frame/token helpers. The 302-line resident facade remains a cohesive ownership/reservation lifecycle with resource and recording helpers already separated. Neither requires another extraction to apply this bounded lookahead change; further refactors should remain separate from this preservation delta.
