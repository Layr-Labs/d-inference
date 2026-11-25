# Resolved source review finding: lazy inert parameters

The initial unfrozen pair draft incorrectly inferred a final whole-model eval
from the full-reference loader. Root identified the distinction before any pair
compile or execution. The unchanged `materializeVerifiedQwenLayerStage` evaluates
and fences each active tensor, then freezes and inspects layout; it explicitly
does not evaluate unused placeholders or constructor defaults.

The corrected budget retains both stage inert allocation allowances throughout
stage1 and after completed2. Completed active tensors are charged through actual
allocator observations while both models are explicitly retained. Report fields
state active-parameter evaluation and possibly lazy inert parameters; no new eval
or physical residency assertion was added. The pure fixture checks retained inert
R at both completion boundaries. Its successful predicate would still not prove
that the actual native gate or materializer executed.

The earlier transport review is historical and withdrawn on this point. The
corrected runtime/fixture review `7286ae95…2a529d` and overflow-only supplement
`19af68c1…fee31` cover the final source. These are source reviews, not executions.
