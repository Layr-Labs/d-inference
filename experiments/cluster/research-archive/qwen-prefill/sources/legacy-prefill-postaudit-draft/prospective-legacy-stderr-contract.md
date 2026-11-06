# Prospective legacy-only stderr contract

2026-09-14. Proposal only; the frozen runner, oracle and existing failed receipt
are unchanged. The numerical supplement passes the unchanged legacy CPU checker
while explicitly retaining the launcher's overall **failed** status.

The observed 58 UTF-8 bytes are exactly:

```text
[bf16] converted 124 params (0.1 MB) fp16→bf16 in 40 ms
```

The original failure is correct under the runner's frozen empty-stderr rule.
It must not be relabelled as a successful launcher run retrospectively.

## Source origin

Pinned `libs/mlx-swift-lm/Libraries/MLXLMCommon/Load.swift` SHA-256:
`f700d1cf63e98dcb20b49ba68ffe9c6ed84e9224f942f7b095161667bb577187`.

- Lines 260–262 invoke `convertToBFloat16` only when the effective
  `DARKBLOOM_BF16_WEIGHTS` value is `1`.
- Lines 288–296 collect only Float16 parameters and return without output when
  that set is empty.
- Lines 346–351 format the converted count, binary-MiB byte total to one decimal,
  elapsed milliseconds to an integer, and write the conversion line to stderr.
- The old fixture's ordinary baseline load calls this library path. Its third
  loader result records exactly 124 source-Float16, loaded-BFloat16 tensors,
  totaling 127168 bytes; `127168 / 1048576` rounds to `0.1` in that format.
- The separate recording smoke uses the verified diagnostic loader. It does
  not add another invocation of this ordinary-loader logging path.

The model-update error message in the same conversion function is a different
line. It must remain a hard failure even though it shares the `[bf16]` prefix.

## Minimal optional v2 rule

A new, separately frozen runner version may explicitly select this stderr
policy only for the fixed legacy `qwen-layer-stage-check` 65/32/4 workload,
with the pinned source/binary/environment and its intentional metadata fixture.
All existing resource, deadline, output-size, source, native-exit, process-group
and numerical checks still apply. The new profiled matrix continues to require
stderr to be empty because it has no Float16 metadata fixture.

For that legacy-only policy, require exactly one complete UTF-8 line and no
other byte. Match this entire grammar, then parse and bound its milliseconds:

```text
\A\[bf16\] converted 124 params \(0\.1 MB\) fp16→bf16 in (0|[1-9][0-9]{0,5}) ms\n\Z
```

Require the parsed elapsed field to be at most 180000 for the fixed 180-second
native timeout. Its value is diagnostic text, never inference timing evidence.
Do not match only a substring or prefix, accept multiple lines, arbitrary
counts/sizes, missing newline, invalid UTF-8, carriage returns or trailing data.
Do not permit the library's model-update failure line or unrelated stderr.

After the unchanged numerical checker passes, cross-check the third loader's
124 Float16-to-BFloat16 entries and 127168 converted bytes. This prevents an
expected-looking line from being accepted without the intended fixture.
Raw stderr and its SHA remain archived; the new receipt should record the
explicit policy name and parsed count/bytes/elapsed text separately from its
overall outcome. It should retain primary, cleanup and post-run failures.

Before a new runner is frozen, add CPU mutation cases for a second conversion
line, an error line, changed count/size, signed/fractional/out-of-bound elapsed,
missing newline, extra bytes and applying the policy to the profiled workload.
This is prospective admission for a future run, not a change to old evidence.
