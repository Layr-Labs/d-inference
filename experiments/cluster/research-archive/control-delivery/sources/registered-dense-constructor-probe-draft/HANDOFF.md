# Registered dense constructor probe

> Last updated: 2026-09-14 · commit `e4df336bc`

This is an outtree source proposal. No Swift compilation, constructor execution,
checkpoint hashing, new header read, model payload read, GPU operation or SSH was
performed by its author. The root owns compilation and independently guarded
execution. The Foundation fixture is prospective: 11 positive checks and 41
rejections, including a real `VerifiedCheckpoint` on six invented file bytes.

Use the separate closed entry:

```text
cluster-inference --mode qwen-dense-constructor-check \
  --model-dir <absolute-directory> \
  --registered-dense-profile registered_qwen35_9b \
  --timeout-seconds 120
```

The other accepted profile is `registered_qwen38_27b`. All four argument pairs
are required exactly once; order may vary. Timeout is a canonical decimal integer
in 1...300. All other flags reject, including cuts, prompts, traces, transport and
weight-loading modes. The separate `main.patch` dispatches before `Options` and
is disjoint from the readiness mode's adapter and preflight insertions. Its entry
installs its own `alarm`, monotonic deadline and bounded metadata reads. It admits
the existing exact query128/BF16=1/TF32=1 environment and absent GPU_ARCH/SDPA_BLOCKS
before native calls. This reuse identifies policy; no attention or GDN math runs.

Apply `bridges.patch`, add the eight `QwenDenseConstructor*.swift` files, then apply
`main.patch` at its pre-Options seam. No Options or provider change is proposed.
Root should preserve any later Main changes when applying that small hunk.

The call is `runQwenDenseConstructorProbe(directory:admission:check:)`. Its private
admission constructor accepts only the two exact raw configuration/manifest pairs
and default halves (16/16 or 32/32). `VerifiedCheckpoint` streams the manifest's
whole files once, before any full model constructor, under the exact registered
aggregate/raw-manifest/total-byte identities. Hashing reads file bytes but does not
install or evaluate tensor values. The new `configurationSHA256` and
`requireConfiguration` bind a reused checkpoint to its verified config. The new
`PreparedQwenCheckpoint(checkpoint:...)` overload rechecks descriptor identities
and config; its sanitizer/composition/quantization tail is unchanged. It never
performs a second full-file verification.

The real full constructor supplies actual sanitizer names, expected shapes and
packed classes. Its canonical descriptor projection must independently pass the
existing closed registered inventory signature, complete Plan mapping and
registered observed-source validator. `finishPreparedQwenLayerSource` is extracted
without logic changes from the existing source assembly. The old entry still
uses its existing 8 GiB manifest and 6 GiB source/512 MiB host limits. Neither
existing materializer is wired to a new admission.

Each compact constructor then uses unchanged `prepareQwenLayerStageModel`, including
local quantization remapping, exact active/inert key coverage, source shape and
packed-class checks, and inert replacement shape/dtype checks. The registered
compact validator checks its *prepared expectations*. Actual constructor parameter
names, shapes, dtypes and logical bytes are captured separately. Full floating
parameters are expected to be F32 defaults; active compact floating parameters
remain F32 until loading; the installed compact placeholders are BF16. Stored
BF16 source records and `expectedPostLoadSummary` do not establish loaded values.

Full and compact models each live in a scoped random state and autorelease pool;
only CPU records survive. Weak model checks precede the next constructor or
success. A failure inside a compact helper before it returns still relies on
that helper's local unwind; the probe does not claim absence of every native alias.
The final CPU result escapes its descriptor scope, then stream cleanup, weak file
owner release, cache clear and native/deadline checks gate publication. Native
errors are preferred over a secondary Swift metadata error, and cleanup failures
are reported with the primary failure. No success JSON is emitted on failure.
External process deadlines remain required for blocking native work or hashing.

The sole success record is `qwen_dense_constructor_report`, schema 1. Exact fields
are in `QwenDenseConstructorTypes.swift`. Source tensors, full constructor and two
stage observations are bounded by closed counts (927 or 1,847 source parameters;
three constructors; at most 2,048 parameters each). Full/stage parameter metadata
hashes use the existing sorted-key JSON encoder. The report explicitly denies
weight installation, tensor evaluation, forward/state execution, numerical parity,
provider eligibility, independent resource admission and whole-process memory
bounds. The report is source-bound evidence, not an independent observer.

`fixture-source-list.json` supplies 15 exact Foundation/CryptoKit/Darwin source
inputs plus the shared retained stdin file, with no copied metadata. Root may
compile those paths using `xcrun swiftc -parse-as-library -swift-version 6
-warnings-as-errors ... -o <outtree-check>` and run it with the recorded stdin.
The actual constructor fixture uses only a new mode0700 temporary directory and
invented config/payload bytes; it exercises exact config reuse, same-length wrong
config rejection and legacy payload-cap refusal. No MLX is linked by this check.

`source_check.py` verifies the unchanged assembly/canonicalization tails, old
caps, exact CLI/deadline and native-error gates, actual descriptor/constructor
calls, CPU result scope and pinned dependencies. Eight source mutations reject.
These are structural checks, not a Swift compiler or runtime proof. Historical
fixture/source manifests remain unchanged. Actual executable/bundle/source-archive
correlation and run resources belong to the root's guarded driver and separate
metadata oracle.
