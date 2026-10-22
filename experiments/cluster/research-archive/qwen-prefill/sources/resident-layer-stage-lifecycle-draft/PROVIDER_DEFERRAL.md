# Narrowed first reuse boundary

2026-09-14. Additive supplement to the frozen resident reuse plan
`2c227b8b96c2d89946e44a98d514e5bacd1b9768f6a8d067de0b19b2de502d0a`.
The old plan and its pending review annotations remain unchanged.

Defer the proposed provider seal. It is unnecessary for the first qualification
of an exclusive, privately created resident owner. That owner retains the actual
verified Loaded stage, admits no externally supplied model or copied receipt as
ownership authority, exposes no model/array getter, and uses the existing pinned
forward implementation and StageSession path/dtype/shape/frozen checks. The load
receipt continues to describe verified materialization at load time. It does not
certify that later fused child views remain independent compact allocations.

The existing source does not establish a fusion-induced layout refusal. A seal
would be separate future work only if a cohort claims inspected physical lineage
from registered views to fused parent allocations. No provider/submodule change,
extra forward pass, evaluation hook or weight readback is proposed here.

The reusable function is `runQwenLongPrefillRankRequest`; its outer Check enforces
one-shot model release and must remain unchanged. A new private owner will retain
the verified stage and group, rebuild the existing CPU admission and agreement
with a fresh request UUID and wire epoch, then call that request function inside a
fresh autorelease scope. Its existing readiness exchange is the next-request
barrier, reached only after each rank has returned from its previous local scope.
Use nil phase and owner observers initially; their one-shot recorders cannot be
shared. No request context, cache rows, transport, tickets or final-logit handles
are reused. Repeated histories, including A/B/A, remain valid.

The pure gate in this draft only enforces finite, nonoverlapping CPU scopes and
failure fencing. It cannot prove native cancellation, array lifetime, loader
identity or physical storage. Its generic callback is private-owner machinery,
not a public arbitrary inference callback. Final release must drop the owner's
actual model capability, synchronize and check the weak model reference using
the existing outer cleanup pattern. A callback returning after a failed native
cleanup does not become a successful retirement claim.

This narrowing incorporates the parent decision and pipeline source review. No
new native execution, compiler run, GPU test or performance claim occurred.
