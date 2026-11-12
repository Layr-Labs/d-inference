# Gemma resident unread staging correction — 2026-09-20

The actual 8K/C64 solo refusal was 173,345,359 B (165.315 MiB) below its live free-memory requirement. It failed with completed=79/pending=79 of1,339 tensors; the pending tensor was a512-byte BF16 attention norm. The first79 selected tensors total1,329,896,964 B versus1,330,038,240 B MLX active at refusal. The allocator allowance itself had ample room. The parent retained failure, reaped its native group and proved the canonical journal empty. This package changes no physical evidence.

A new F_NOCACHE change is not justified: VerifiedCheckpoint already uses F_NOCACHE during hashing, then Gemma's materializer sets F_NOCACHE=1/F_RDAHEAD=0 on every tensor descriptor. Aligned anonymous scratch is explicitly munmapped before the MLX copy. These are requested cache policies, not proof that all OS file cache is absent. The39 retained OS samples show prelaunch→last-live file-backed growth224,018,432 B and anonymous growth1,732,706,304 B. They are system-wide samples and do not attribute that growth to one process or allocation. The last parent sample also precedes the exact native refusal observation.

The concrete correction concerns a provably completed staging obligation. The owner currently reserves the largest tensor's future host read and future native copy throughout the load. That largest tensor is the embedding (369,098,752 logical bytes), already completed by ordinal79. No subsequent read in this ordered one-pass materializer can read it again. The largest unread tensor is126,877,696 B. The existing Gemma4OrderedLoadProgress advances only after the per-tensor read/convert/update autorelease scope ends and after all native checks; authorization alone does not advance it. The pending tensor remains included in the unread suffix at every intermediate check.

`Runtime/Gemma4BenchmarkUnreadStaging.swift` computes maxima over precisely that suffix, using lazy existing metadata views and no new retained allocation table. It separately takes the maximum of actual allocation bounds, without assuming their order follows logical sizes. `Runtime/Gemma4BenchmarkResourceOwner.swift` replaces only the two fixed staging lookups with these values. All resident-weight remainder charges, currently live native observations, future request/KV/cast/activation terms, host evidence, aligned-reader scratch, constructor allowance, zero-cache requirement and6/4/2 GiB floors remain unchanged. Completed model weights remain resident and observed; this change does not claim they were freed.

The actual successful P1024/C128 full result from the same18d99 benchmark binary retained all1,339 native allocation bounds. With the unchanged source inventory, it provides the following counterfactual at the failed ordinal:

| Allowance | Previous bytes | Unread suffix bytes |
|---|---:|---:|
| Host read | 369,098,752 | 126,877,696 |
| Native copy | 369,131,519 | 126,910,463 |

The combined reduction is484,442,112 B (462 MiB). Applying only this arithmetic to the original refusal observation gives required30,566,451,791 B against actual30,877,548,544 B, a311,096,753 B (296.685 MiB) margin. Initial admission is unchanged for the observed allocator policy. This is not a new run, whole-cohort fit guarantee, or claim that OS activity will repeat. The runtime still obtains its own current actual allocation bounds and observations; it never consumes this previous receipt as admission authority.

Apply the exact two-file overlay from `integration.json` to a fresh/current authorized private benchmark candidate. The sole existing-file preimage is the18d99 baseline ResourceOwner. `runtime.patch` is its complete delta. There is no Package.swift change because the helper joins the existing Runtime target. The added pure checks have8 groups covering initial maxima, pending retention, completed-prefix retirement, exhaustion, invalid frontiers/inventories and nonmonotonic allocator-bound ordering. They have not been compiled or executed by the author.

For root's next bounded CPU slot, compile exactly the helper and checks with Swift6/warnings-as-errors, using the existing owned60s/jobs2 wrapper and fresh output files, then run that CPU binary under an owned30s bound:

```sh
swiftc -swift-version 6 -warnings-as-errors -O -j 2 Runtime/Gemma4BenchmarkUnreadStaging.swift Tests/UnreadStagingChecks.swift -o CHECK_OUTPUT/unread-staging-checks
CHECK_OUTPUT/unread-staging-checks
```

Then rebuild only GemmaResidentBenchmark in the qualified disposable workspace, retain a new binary/source identity, and reuse the same P8192/C64/O16 full-row/state comparison sequence with fresh job/output names. The P32 short harness remains untouched. Do not proceed to C32 or change the512-control bound as part of this correction. The fresh binary's existing native metadata/argument checks and actual resource guards remain required.

Arithmetic's lookahead override has only separate optional-policy/receipt edits. `lookahead-composition.json` pins its exact901fdf11 Owner and the expecteda89a4ba2 composed result; `lookahead-composition.patch` applies this same staging change without altering those lookahead edits. Add the same helper exactly once. This is an explicit alternative composition, not authorization to overwrite its frozen source.

Applicable AGENTS guidance: retain the existing single owner, exact state transitions and failure cleanup; make a small reviewable change, trace all related readers, and qualify the behavior using relevant checks. No MAIN, frozen candidate, vendor, floor, native lifetime, signing, remote or GPU changes were made here. `context-pins.json` binds the exact source/evidence read; `analysis.json` preserves calculations and limits.
