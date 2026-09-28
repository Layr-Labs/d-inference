# V2: complete arithmetic-environment DTO

V1's exact arithmetic-environment dictionary omitted five fields from the actual
`QwenLongPrefillArithmeticEnvironment.Receipt`: `defaultBindings` and the four
true qualification fields `actualProcessEnvironmentMustBePassedBeforeMLXInitialization`,
`sourceBinaryMetalLibraryAndHardwareIdentityStillRequired`,
`sameChunkFullModelReferenceStillRequired`, and
`doesNotValidateOtherTimingOrResourceEnvironment`.

The native `QwenDenseStageLoadReport` directly encodes that full receipt. V1's
fabricated records copied its incomplete dictionary, so its 12 fake methods and
source checks missed the nested schema mismatch. The author and independent
source review also missed it. The original package and reviews remain unchanged.

Root reported that the first actual stage-0 audit failed with
`ValueError: Wrong metadata keys at arithmeticEnvironment`. The failed result
remains at `runs/dense-stage-load-9b-stage0-v2-peer24-20260914/loaded-metadata-audit.json`,
SHA `df7faca9aab7b9ec4c40eaf7a3a1abad2f6ac8b3c72a5553f3797ec10020b270`.
Root supplied its native stdout pin
`cf1aff98c28fbaba2ea1993f63322a18185c7a318680116066a9bdc4a007f7eb`.
Neither file was read for this correction. Native and parent results retain
their original statuses; the second stage had not been audited at diagnosis.

V2 adds exactly those five fields, including all five literal `defaultBindings`
values, to the runtime dictionary. Exact keys and exact types remain required.
All tensor ownership, dtype, layout, inert metadata, storage, raw input,
structured failure, and qualification comparisons remain unchanged. The CLI and
result schema are unchanged; use this separate frozen folder and a new output
path such as `loaded-metadata-audit-v2.json` to distinguish the replay.

Tests now derive the arithmetic fixture from a pinned copy of the real Swift
source, not from the oracle's expected dictionary. The source checker compares
every DTO field and literal value, verifies the actual report wiring, and checks
that all original 12 test method bodies are unchanged. Four new fake methods
cover the full source DTO, the old incomplete subset, missing/extra keys,
incorrect default strings, strict Boolean/integer types, and a retained failed
receipt that cannot overwrite an existing result.

The native arithmetic source SHA is
`b6b9036557a3a937a454d0a8e1b3ba6032954a93c2ded370a97b23d6f984454f`.
This is a source-based correction after root observed V1's candidate failure;
it is not a pre-execution or blinded review. No candidate output, tensor payload,
native process, compiler, SSH, or GPU access is performed by this package work.
All metadata-only and unqualified numerical/resource/lifetime limits from
`PLAN.md` remain in force.
