# Exact isolated native-key prelude validation procedure

This is a source-only preparation recipe. Nothing has been materialized or
compiled; no vector/crypto child, model, remote or RDMA operation has run.
The source helper combines only frozen prelude A `23fce2b6…f105afb` with the
reviewed fixture-only correction `c96e6e0a…5ef767c`. It does not change runtime,
runner, dependencies, timeouts, assertions or the original frozen evidence.

## Copy scope and bindings

`prepare.py` verifies all46 A members and all6 correction members before creating
anything. It also verifies the20 retained dependency originals/copies. It builds
an in-memory copy plan below512KiB, replaces only `Tests/NativeKeyChild.swift`
after its exact preimage check, and retains all nine runtime hashes unchanged.

The new `source/` contains A's46 declared members with that one replacement,
plus four provenance files: both original manifests, the fixture correction
patch and the exact combination record. The generated manifest is byte-for-byte
`expected-combined-manifest.json`; it has50 members (51 copied/generated files
including the manifest). No entire-folder copy, dependency cache, model, SwiftPM
workspace or symlink is used. Extra future review files outside input manifests
are not copied. A fresh direct child of cluster-research is mandatory, with
exclusive creation and partial failures retained. Original inputs and complete
output member set are checked again after copying.

The output manifest is compatible with the unchanged `Tests/run.py` reader.
It records all combined sources and provenance, and the test runner verifies it
before/after each child process. Generated binaries/logs live in a sibling checks
directory, outside the immutable combined source. The existing owned helper,
PID-bound socket fixtures, exact-error correction and all regression fixtures
remain unchanged. `combination.json` pins the runner/helper and nine runtime files.

## Root-run sequence — grant still required

```sh
cd /Users/developer/DarkbloomDev/cluster-research/cluster-native-key-prelude-validation-plan-20260916
/usr/bin/python3 -B prepare.py --output /Users/developer/DarkbloomDev/cluster-research/cluster-native-key-prelude-validation-1-20260916
/usr/bin/python3 -B /Users/developer/DarkbloomDev/cluster-research/cluster-native-key-prelude-validation-1-20260916/source/Tests/run.py --output /Users/developer/DarkbloomDev/cluster-research/cluster-native-key-prelude-validation-1-20260916/checks-1
```

Run these sequentially only after root grants the quiet compiler/CPU slot.
The first command only copies the bounded source plan and writes a preparation
receipt. The second is the previously reviewed CPU runner: six Bootstrap and
12 Security source files; Swift6/warnings-as-errors/macOS14, max2 jobs, fresh
module cache; 60-second compile bounds, new fixture30s, legacy fixtures10s,
450-second whole runner alarm. It uses no SwiftPM resolution or MLX compilation.
The installed OpenSSL library is hash-checked before independent vector creation;
no dependency download or install is allowed.

The expected checks are seven new groups/23 actual local native-key children,
five unchanged legacy bootstrap groups/12 children and16 unchanged codec/adapter
groups:28 groups and35 children total. Each new child has an independent4s alarm.
Only public prelude records and ciphertext fixture records cross local pipes;
no model/RDMA/coordinator/native-approval qualification is claimed.

Success requires the runner's final `checks.json` passed=true, empty stage stderr,
actual process reaping/group absence, expected method output and stable source
rechecks. Preserve any compiler/runtime failure, original source tree, raw logs
and preparation receipt. Make a separately pinned source correction before any
rebuild; do not edit either original freeze or this reviewed runtime in place.

## Existing source reviews

Pipeline's complete combined source review:
`cluster-native-key-prelude-review-20260916/source-review.json`
`61f33b3ce3a54321d70d6d4113c853a4477b76b462b7ee7ad7ecc34015ea1a2a`.
Arithmetic's narrow authority/cancellation review:
`cluster-native-key-prelude-authority-review-20260916/source-review.json`
`abc033f07b684dd19a0bf9974104428442befac0700448f83049afd1b36d7e24`.
Both were source-only. This recipe does not broaden their review scope.
