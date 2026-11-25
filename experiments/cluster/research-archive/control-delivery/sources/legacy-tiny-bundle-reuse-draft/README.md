# Legacy tiny regression with optional bundle reuse

`run_tiny_stage_check_v2.py` preserves the original tiny driver's workload,
resource, timeout, output, process-owner and stderr rules. It adds only paired
`--reuse-bundle PATH` / `--expected-bundle-manifest-sha256 SHA` arguments using
the exact reviewed helper `c4832e457307f683f5aff55cafefe6feeeaf6a69ad1be2dc220325f96f5da8a4`.
Without both arguments it uses the original fresh snapshot path.

Root should use `--workload legacy`, the complete current native SHA, a new
output directory and, if available, a newly reviewed source-matched bundle:

```text
python3 run_tiny_stage_check_v2.py --workload legacy
  --expected-native-sha256 <complete current source-matched native SHA>
  --output <new outside-repository run directory>
  --reuse-bundle <reviewed owned read-only bundle directory>
  --expected-bundle-manifest-sha256 <independently pinned raw bundle.json SHA>
```

This selects the existing synthetic `qwen-layer-stage-check`, CBv2 contiguous,
65/32/4, one repeat, zero warmups, native180/parent195 seconds. Initial/prelaunch
actual free >=1GiB, pressure<=2, no new reported swap, no competing native job,
8MiB stdout/64KiB stderr bounds and process-group cancellation/reaping remain
unchanged. The profiled workload option already present in the original remains
available; this handoff requests only the legacy regression.

Reuse creates an explicit new `output/bundle` symlink, fresh source archive,
observations and receipt. The receipt identifies external reuse and copied=false,
records the helper and bundle identities, and adds an independent reference
postcheck. The helper checks exact owned read-only files/tree, manifest/native
hashes and current archived `rank_worker.py`/`artifacts.py` equality. Do not reuse
an older-binary bundle for the new tail extraction. Root also reported a
readiness worker created an unlisted writable `__pycache__` in an older bundle:
that tree must remain refused by these unchanged checks, with its evidence
retained. A fresh bundle with the corrected worker/source identity is needed;
there is no pycache allowance or cleanup operation in this package. This tiny
driver executes the native binary directly, not `rank_worker.py`.

**The empty-stderr requirement is unchanged.** A native0 run that emits the
ordinary BF16 conversion diagnostic still returns parent failure. In the prior
loader regression this was the sole primary failure, with a separate native
evidence supplement and unchanged numerical replay. The expected-format line
is an ordinary-loader diagnostic, not a new accepted stderr class. Elapsed
milliseconds are variable and are not a qualification metric. No old receipt,
helper or failed output is edited or reclassified.

After root confirms the new process is terminal, retain its parent receipt and
apply the unchanged thirteen-record CPU oracle separately:

```text
python3 -B ../tiny-unequal-audit-v2-draft/tiny_unequal_audit.py <new stdout.jsonl>
```

Pin the oracle's manifest `63a6473291a72869aad501510824e2f12dbd149143380322f61277b7603f3f5d`
and all members before replay. It independently checks the saved metadata,
state geometry/fingerprints and exported full BF16 rows; per-entry state bytes
remain opaque. Native source/bundle provenance, resources, cleanup and the exact
stderr explanation stay separate. A normal-line-only parent failure can be
reported alongside a narrower successful native/numerical regression without
claiming launcher success. Current source/binary correlation is required; the
old supplement is historical evidence only.

Five fake wiring tests passed: default snapshot, reference without copying,
paired-argument refusal, retained normal-diagnostic parent failure, and a
reference postfailure that preserves the primary stderr failure. All process,
observation, archive and bundle-validation operations were mocked in those
tests. The reused helper's own nine invented-bundle tests remain in its original
package. No new actual bundle, candidate, model payload, native/compiler/SSH or
GPU execution occurred while creating this adaptation.
