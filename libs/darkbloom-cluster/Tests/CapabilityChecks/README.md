# Runtime capability Protocol checks

Run `./Tests/CapabilityChecks/run.sh` from the shared package. This compiles the actual Protocol sources with Swift 6 warnings-as-errors, exercises canonical decoding and refusal cases, and runs the unchanged existing Protocol checks against that same module. It uses Foundation only; no model or native worker is launched.

The 3.7 KiB canonical fixture is produced from the current registered Qwen3.5 9B adapter metadata. Its runtime binary hash is deliberately 64 ones: a fabricated codec input, not an installed build or readiness claim. The separate worker metadata suite checks the actual producer against these profile/Plan/arithmetic identities.

Coverage includes duplicate decoded keys, missing/extra fields, integer overflow and Boolean confusion, noncanonical numbers/bytes, unknown adapter/profile/partition/policy, malformed intervals and exact declared Plan selection. The decoder validates declared consistency; this suite does not recreate native Plan legality or attest binaries.
