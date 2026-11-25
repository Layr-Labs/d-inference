# Registered dense resource profiles

Private overlay. One new Foundation file makes registered source
and named-state limits explicit; three resident files consume those values.
No provider, coordinator, CLI, capability descriptor, Plan admission or loader
materialization policy is widened. No MAIN file or frozen artifact is changed.

`QwenDenseRegisteredResourceProfile` binds the closed specification or an already
admitted complete metadata profile. It derives geometry from the selected model
and independently checks the8320/512 maximum byte vector. A separate bounded
metadata calculation accepts context1...8320 and chunk1...512, with chunk no
larger than context. This is not an execution or memory permit.

| Limit |9B|27B metadata only|
|---|---:|---:|
|Manifest payload ceiling|8,589,934,592 B, unchanged|16,320,415,757 B, exact registered manifest|
|Named state ceiling|805,306,368 B, existing768 MiB constant|1,616,248,896 B, exact maximum vector|
|Actual8320/512 named-state vector|754,188,320 B|1,616,248,896 B|

For admitted9B, `QwenResidentSource` uses exactly the prior8 GiB ceiling.
`QwenResidentAdmission` and `QwenResidentRequestResources` retain their original
budget calculations and compare to exactly the same9B ceiling. All three
retain their existing explicit9B admission checks. The old output1 admission,
encoded receipts, limits, errors and32/32-only27B planning scope are untouched.
The maximum profile calculation does not replace the existing generation
allowance, allocator rounding or live gates. The six-GiB physical floor,
four-GiB resource headroom, two-GiB allocator headroom, selected fusion charge,
full-model conservative state charge and MTP-off execution remain unchanged.

The only existing runtime replacements are:

- `QwenResidentSource.swift`: get the registered manifest byte ceiling before
  constructing VerifiedCheckpoint; keep raw manifest/config/artifact verification.
- `QwenResidentAdmission.swift`: get the selected registered named-state ceiling;
  keep the literal9B execution gate and unchanged budget formula.
- `QwenResidentRequestResources.swift`: bind the already-admitted profile to the
  registered resource values; keep the literal9B gate and all per-array accounting.

The new source is `QwenDenseRegisteredResourceProfile.swift`. Integration requires
adding it to any explicit standalone source lists compiling these three callers;
SwiftPM automatically includes it in the existing Runtime target. No package or
product API changes are needed.

`QwenResidentLoading.swift` is byte-for-byte absent from this patch. Arithmetic's
frozen nine-file MTP loader overlay modifies that file and adds separate MTP
types; this patch has no source overlap with those nine files. It also leaves
the existing MTP-off source guard and resource allowance intact. The MTP overlay
must still be applied/tested on its own reviewed build; no combined build claim
is made here.

Validation:

- `python3 check_source.py`: three inverse transformations restore all original
  runtime bytes exactly;11 compatibility files are pinned and not replaced.
  This includes legacy policy, physical guard, Worker/Capability and M5/NAX gates.
- `bash -n Tests/run.sh`: runner syntax check only.
- `bash Tests/run.sh`: **PASS**, first attempt,3.262205417 s, exit0 and empty
  stderr; all checked source pins unchanged. The18-source standalone
  Foundation/CryptoKit fixture ran the exact existing retained profile suite
  (37 accepted/53 rejected), then13 accepted/26 rejected new checks. It checks
  then checks per-model8320 vectors,9B legacy receipt/budget equality, source
  bounds, invalid context/chunk values, unchanged27B non-default-cut refusal and
  rejection by the old9B long-prefill admission. No model or MLX is imported.
  Exact invocation, output and source stamps are under `checks-1/`.
- Native/MLX typecheck, full Provider suites, actual resource observations and
  execution remain root-owned and unperformed.27B execution is still refused.

Independent source review is pending at this freeze; root has the four-file
reviewable patch and inverse-delta check. No native typecheck is implied by the
Foundation fixture: it compiles the new pure definition and metadata dependencies,
not the three MLX-facing caller files.

The previous mapping remains frozen separately at
`qwen27b-installed-runtime-map-20260915`; this overlay implements only its bounded
resource-definition seam, not the wider executable-profile/policy changes.
