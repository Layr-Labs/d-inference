# Native registered 8K selectable cut proposal

Source draft, 2026-09-14. Root owns integration, compilation and all native execution. This package makes no new numerical, memory-safety or throughput qualification.

Apply `runtime.patch` against the 16 sources pinned in `base-inventory.json`; its three new files and all replacements are also in `proposed/`. The patch includes the Main dispatch `try checkQwenLongPrefillStageCutAdmission()` after the short rank-cut fixture, and forwards the pair command's selected cut. No additional Main wiring is needed. `source_checks.py --repository REPO` verifies original bytes, patch equality, 46 untouched source dependencies, narrow runtime deltas and six rejected source mutations. It does not compile or execute Swift.

The CLI admits `--stage-cut` for the existing short comparison/serialized rank modes and the explicit long reference, pair and rank modes. The registered long choices are 4, 8, 12, 16, 20, 24 and 28. Omission means the historical 16/16 plan, including direct runner calls carrying an already admitted plan. All solo modes and the foreign short lookahead/prefill helpers still reject the option before their mode-rewriting clones.

The small new API is `QwenLongPrefillStageCut.resolved(_:)`, `makePlan(configuration:stageCut:)`, `validateBinding(_:plan:)`, and `componentCount(_:)`. The retained-byte reference admission adds `stageCut: Int? = nil`; the pair runner adds the same defaulted parameter before `check`. Existing omitted calls remain source-compatible. Reference and rank preflight pass the selected cut. All three runner entry points bind supplied plan ranges before model work, readiness output or Collective construction.

The registered artifact/configuration pins, 8192/512/1 request, 16-frame history, empty teacher, arithmetic admission, native BF16 and resource ceilings remain unchanged. Request/profile/recorded-request fingerprints do not encode a plan and remain unchanged for the same UUID/input. Plan, stage construction, source evidence, storage and wire agreement identities already encode the actual plan and therefore change for an unequal cut. The full-model reference is produced under that same selected admission and fully released before stages load; an old 16/16 reference cannot be relabeled for a different plan.

Compute admission derives each loaded stage's layer count from the admitted plan instead of requiring 16. The final state digest's additional count assertion derives two GDN components or three full-attention components per actual stage layer. Complete per-key equality, local/global mapping, shape/dtype/byte counts, native snapshot fingerprint and summed byte checks remain byte-for-byte unchanged. Cut12 consequently describes 27/45 state components; no count-only acceptance is introduced.

No wire, report schema, source loader, profile, request schedule, native operator, state owner, selection, timer or tracing implementation changes. Original `DEPENDENCIES.md` and its pins remain preserved; `DEPENDENCIES-v2.md` records the additional state-count lock and explicit nil binding requirement.

Prospective adapter expectations, not executed in this draft:

| Record | Accepted | Rejected |
|---|---:|---:|
| New long cut CLI/preflight | 13 | 58 |
| New synthetic plan cases, nested in that record | 8 | 14 |
| Existing short comparison-cut fixture | 8 | 50 |
| Existing short rank-cut fixture | 8 | 47 |

The existing short fixture counts decrease only because three long modes are newly admitted. New checks prove all seven legal ranges, complete global-layer ownership and inverse parameter mapping, fixed embedding/norm/head responsibility, historical default construction identity, foreign geometry refusal, stale nil/explicit plan rejection, long-solo cloning refusal and invalid cut refusal before unused file paths are read. They explicitly do not exercise registered artifact admission or construct a model.

Before any cut-specific qualification, root still needs the canonical build and adapter checks, a fresh same-plan registered full reference, selected-plan stage correctness, and prospective launcher/auditor metadata for the actual range. Existing public/private long launcher and CPU oracle default-half assumptions are being mapped separately; this package exposes no new Python flag and changes no retained oracle. Measured split costs require actual qualified runs with their resource and local-clock limits retained.
