# Resident benchmark worker CLI and retained admission

Three additive Foundation-importing source files; no existing source is edited.
The root owns target integration, compiler execution and native qualification.

`QwenResidentBenchmarkWorkerCLI` exposes `isRequested(_:)`, `init(arguments:)`,
`role`, `timeoutSeconds`, `modelDirectory`, `tokensFile` and `options(open:)`.
The exact worker mode is `qwen-resident-benchmark-worker`. Required pairs are
`--mode`, `--role solo|rank`, `--model-dir`, `--tokens-file`,
`--artifact-aggregate-sha256` and `--long-prompt-sha256`. Paths must be absolute
and at most 4096 UTF-8 bytes. Optional timeout is a canonical integer in 1...300,
default 300. Rank requires an explicit existing `--stage-prefill-policy` and
optionally admits `--stage-cut` through the existing native cut selector. Solo
rejects both rank options. Every flag is unique; no geometry, precision, epoch,
trace or repeat override is accepted.

`preflight(open:arithmetic:read:)` takes the entry-owned `(URL, Int) throws -> Data`
reader. It validates the opening command and actual Options first, reads config
once with the 1 MiB cap, verifies its size, then reads the prompt once with the
64 KiB cap. `admit(open:arithmetic:configuration:prompt:)` is the pure retained
input seam. Both return `QwenResidentBenchmarkWorkerAdmission` with `options`,
four actual registered `requests`, and four `rankRequests` for rank or an empty
rank list for solo. Each native UUID derives from that opening request's epoch.
Both role-specific resident admission validators run before return.

The existing admission constructors remain responsible for registered 9B
source identity, native arithmetic policy, Plan and 8192/512/B1/output1 request
geometry. This adapter does not load weights, attest the process environment,
admit actual resources, grant request permission or make filesystem safety
claims. The entry owns those operations and the one fixed cohort deadline.

`checkQwenResidentBenchmarkWorkerCLI()` returns the Encodable
`QwenResidentBenchmarkWorkerCLICheckResult`. Source-derived expectations are
12 accepted and 67 rejected cases. It reuses the existing retained
`QwenLongPrefillResidentRankFixture`; it adds no metadata copy. Checks cover
actual Options and four admitted request identities, both policies, selected
cut, fixed geometry, exact injected read counts/caps, pre-read refusal, retained
byte/pin mismatches and original reader error propagation. These are CPU
admission/callback checks, not filesystem or live resource checks. No compiler
or fixture was executed by this author.
