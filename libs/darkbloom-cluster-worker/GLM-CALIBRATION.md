# Private GLM calibration contract

This is not a catalog registration, workspace qualification, or installed-pair
readiness claim. It accepts only cold text, greedy batch one, one request with
at most 2048 prompt tokens, 2048 tokens per chunk and 16 output tokens.
The signed selection must reserve context for prompt plus output, up to 2064
tokens; smaller existing selections retain their exact bounds. No MTP, vision, prefix reuse,
keep-warm, recording runtime, or public token stream is supported.

## Authorization and launch

The parent member launcher owns signing and installed routing. Invoke the worker
with `--glm-calibrate` before its normal private-GLM arguments. The existing
`--glm-qualification /absolute/file` points to a calibration document for this
entry point, not a serving qualification document. Keep
`--qualification-switches yes --keep-warm off --data-plane encrypted_v1` and the
ordinary authenticated rank identity, lease, and bootstrap fields. Supply the
existing data-plane credential on stdin. Never put credentials in arguments.

The JSON envelope is `GLM5NextWorkerQualification.SignedDocument`: base64 payload
bytes and a raw 64-byte P-256 signature. Sign the exact bytes prefixed by
`darkbloom/glm-worker-calibration/v1` plus a NUL byte. Its payload is
`GLM5NextCalibrationCommand.Payload`, containing `selection` (the existing
qualification payload with EMPTY workspaceEvidence) and `authorization`
(`GLM5NextCalibration.Authorization`). The separate domain prevents serving and
calibration documents from being interchanged. Epoch, rank, expiry (at most one
hour), artifact, cut, worker binary, explicit capacities and mode are checked
before native work. Authorization is permission for a bounded experiment, not
evidence that its workspace fits the maximum shape envelope.

The selection authority is the verified EigenLabs/GLM-5.3-Flash-MLX-NVFP4-mtp
snapshot at 8841c52a1e8400bd7d3e7e631c916a6c4e6757b0, not the stale 4bit smoke
identity. The launcher must supply its independently verified manifest identity
and bind the final binary/metallib/device/environment. A signed manifest does not
replace verification of model bytes.

## Quotation and execution seam

`GLM5NextCalibration.plan` takes the descriptor, its existing header inventory,
explicit experimental native/host workspace allowances, real allocator bounds,
and an authenticated authorization. It calls the existing resident budget and
LOAD quotation; no workspace floor or separate formula is introduced. It returns
exact native/host/load/request terms and identity hashes. Call it for candidate
cuts using one inspected inventory. It does not admit public cuts.

`GLM5NextCalibration.run` uses the production resident, selected stage, JACCL,
encrypted peer agreement and regular pipeline driver. Its independently supplied
native-cap verifier must attest an already installed allocation-enforcing guard,
not a sampler or a soft limit. Native quotation plus baseline must fit the cap. Host budget and OS headroom are separately authorized.
The caller must retain the bootstrap attachment and force process termination on
success or failure. The runtime retains roots before LOAD, returns no READY or
lease, and has no clean-release/refund result. The parent must observe actual
exits of both ranks before replacement/refund.

The finite child supervisor binds reports to the expected authorization payload
and environment digests. Its expected normalized text-configuration digest comes
from the authoritative quotation; it differs from the raw `config.json` file
digest in the worker identity. A report cannot supply its own expected digest.
The parent additionally checks the detailed quotation against its authorized
plan. An accepted report remains provisional until that child actually exits.

Reports keep native active/peak observations, host malloc observations, and whole
process footprint separate. Do not compute host bytes by subtracting MLX from
RSS or add process footprint to native bytes. Boundary samples can miss transient
host peaks. Reports always say `qualifiesMaximumEnvelope: false` and
`requiresProcessExit: true`; no automatic measured WorkspaceEvidence is produced.
Shape/branch coverage and justified bounds need a separate qualification review.

## Native backing enforcement

`GLM5NextCalibrationNativeCap.install` calls the compiled GLMCalibration SPI before
metadata/native IO. It installs the exact independently authorized ceiling once
and verifies the installed snapshot. Each later check requires that same ceiling,
nonnegative overflow-safe component accounting, charged bytes equal to the component
sum, and charged/peak bytes within the ceiling. Unsupported, missing or mismatched
capability fails; the ordinary soft memory limit and sampled process footprint
cannot substitute for this allocation-enforced backing cap.

The worker now wires the authenticated selection through live environment
validation, descriptor.inspectInventory, plan and run, retaining the authenticated
bootstrap and process deadlines. The installed provider must also complete
authenticated selection and dispatch; a linked cap alone does not authorize a run.
The signed authorization separates nativeHardCapBytes, hostBudgetBytes and
osHeadroomBytes. Only the native backing cap is allocation-enforced. Host malloc
and process-footprint checks are sampled observations and can overshoot; neither
is represented as a whole-process hard cap. Execution first checks baseline plus
native cap, authorized host budget and OS headroom against physical memory.
The cap design and remaining model qualification gates are in GLM-NATIVE-CAP-PROPOSAL.md.

SDK loading still independently hashes its expected source files. No stat-only
or manifest-only verified capability is added. Parent-owned custody work must
provide a safe receipt-bound alternative before repeated real-artifact experiments;
this foundation does not discard global verification receipts or silently skip SHA.

## Focused validation

CPU-only XCTest: `GLM5NextCalibrationCommandTests`.
CPU-only Swift Testing: `GLM5NextCalibrationTests` (synthetic file metadata only).
Build with the native worker recipe, isolated scratch and `--jobs 2`; preserve the
26.2 Swift/C++ deployment target. These tests must not launch the calibration
worker, initialize JACCL, or run model evaluation. Actual RDMA, installed endpoint,
maximum-shape, memory enforcement and teardown gates remain separate.

The cross-target `GLM5NextProviderCalibrationContractTests` consumes the current
provider-emitted signed fixture through `DARKBLOOM_CALIBRATION_CONTRACT_FIXTURE`.
An ordinary worker suite without that fixture reports these tests as skipped.
The dedicated provider-to-worker gate must set
`DARKBLOOM_CALIBRATION_CONTRACT_REQUIRED=1` and provide the exported fixture;
missing or invalid input then fails the gate. `GLM5NextCalibrationLaunchTests` exports the actual prepared entry arguments,
environment, document and public member key after verifying synthetic installed
files. The worker gate consumes those exact fields, strips only the dispatch
flag as WorkerMain does, and runs the real configuration and document decoders.
The credential is checked in memory by the provider test and is never exported.
These CPU checks establish the launch contract; they do not launch a native
worker or qualify an installed RDMA request.

`GLM5NextCalibrationNativeCapTests.testFreshProcessWorkerCapBinding` requires
`DARKBLOOM_TEST_GLM_NATIVE_CAP=1` in a dedicated fresh test process. It executes
real small Metal work through the worker wrapper, rejects a missing or different
ceiling and repeat installation, and rechecks accounting after cache cleanup.
Never enable this opt-in for an ordinary shared-process suite.
