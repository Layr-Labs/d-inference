# 079 — E50 real 8K layer-12 capture: M1 kill

Status: **KILLED. Real top-k4 activations fail every frozen rank/repair cell.**

## Decision

Do not implement activation-subspace contraction with sentinel repair in the
provider. E50 fails the note-078 M1 rule that **every candidate projection**
must pass the numerical and sentinel gates. The first representative real
projection family fails all four quality checks in all 20 frozen cells, so
capturing the other 39 layers, implementing an MLX/Metal primitive, or running
full-model quality would only spend effort after a binding rejection.

This result does not reject every possible prompt-dependent approximation. It
rejects the exact E50 policy and frozen neighborhood:

```text
projection       model.layers.12.linear_attn.out_proj
activation       real CBv2 top-k4 B=1 x 8192, four 2048-row stripes
shape            X[8192,4096] W[4096,2048]
ranks            32, 48, 64, 80, 96
sentinels        16 deterministic output columns
repair caps      8%, 10%, 12%, 15%
power iterations 0
seed             20260824
```

## M3 capture

The run used an Apple M3 Max (16 cores, 128 GB), macOS 26.4, AC power, High
Power mode. `swift build -c release --product darkbloom` completed in
117.43 seconds. The temporary seam was default-off and limited to the layer-12
GDN `out_proj` input in CBv2.

An adjacent run of the instrumented binary with capture disabled created no
capture files. With top-k4 held constant:

| Arm | TTFT | ms/accounted prefill token | first-token checksum |
|---|---:|---:|---|
| capture off | 4,415.875 ms | 0.539113 | `f88780cce381ff53` |
| capture on | 4,458.241 ms | 0.544285 | `f88780cce381ff53` |

The 42.366 ms / 0.959% difference includes four float32 activation writes,
one dequantization, and all quantization-tensor writes. It validates a
non-perturbing capture; it is not E50 candidate timing.

The actual model forward produced four `[1,2048,4096]` BF16 activation
stripes. They were losslessly widened to float32 and assembled as
`[8192,4096]`:

```text
activation-8k.npy SHA-256
2c97896d3a67e1b001bafb23d6296224770c47a9f517612b3365956b8d13a0f9
```

The same runtime `QuantizedLinear` exported its original packed affine W4
tensor, BF16 scales/biases, and BF16-dequantized values widened losslessly to
float32 in input-by-output orientation:

```text
weight shape      [4096,2048]
group/bits/mode   64 / 4 / affine
dequantized SHA   64ed7e90c0c273d9ed6a983340eb099f70021cdeef842c5e74cf434337463428
packed SHA        7a7cca1e0872d4ec9edd13a17bcc93c8681b4d7ce35541dcbb05b109c76f4a52
scales SHA        af171ec3364a18ab5edc0621c7b037c2fad00b2afa9c046030f4c6cbe2245d17
biases SHA        8d883101d2316ddc476186b6e6cb7682da6063326b64fae5aae24d27ebf23257
```

The layer-12 tensors map to
`model-00002-of-00004.safetensors`, whose SHA-256 is
`5d41d9eea6d3810155396ce20316a9e7b34495c366684f824f08c30d6a132f8d`.
The index and config hashes are archived separately.

## Frozen sweep

Thresholds were `c <= 0.30`, NRMSE `<=0.01`, p99 row relative L2 `<=0.05`,
p01 row cosine `>=0.995`, and sentinel worst-row recall `>=0.90`.
`candidate ms` is inclusive NumPy/CPU process wall for basis construction,
basis-through-weight, sentinels, selection, reconstruction, and repair. `wall`
is candidate/reference FP32 projection wall. It is diagnostic rather than an
MLX/Metal M2 measurement.

| r | repair | c | NRMSE | p99 L2 | p01 cosine | recall | candidate ms | wall |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 32 | 8% | .1324 | .4233 | .6821 | .7445 | .666 | 1230.7 | 14.105x |
| 32 | 10% | .1527 | .4122 | .6540 | .7669 | .667 | 64.4 | .784x |
| 32 | 12% | .1730 | .4040 | .6414 | .7812 | .664 | 76.4 | .929x |
| 32 | 15% | .2034 | .3941 | .6191 | .7915 | .668 | 95.3 | 1.130x |
| 48 | 8% | .1548 | .3683 | .5995 | .8068 | .686 | 61.2 | .743x |
| 48 | 10% | .1753 | .3591 | .5836 | .8191 | .674 | 58.5 | .711x |
| 48 | 12% | .1957 | .3515 | .5713 | .8254 | .657 | 64.1 | .779x |
| 48 | 15% | .2264 | .3419 | .5573 | .8340 | .663 | 79.4 | .969x |
| 64 | 8% | .1773 | .3284 | .5662 | .8299 | .712 | 67.9 | .821x |
| 64 | 10% | .1980 | .3207 | .5469 | .8412 | .685 | 81.1 | .972x |
| **64** | **12%** | **.2186** | **.3141** | **.5394** | **.8447** | **.673** | **98.0** | **1.161x** |
| 64 | 15% | .2494 | .3056 | .5253 | .8536 | .677 | 100.9 | 1.202x |
| 80 | 8% | .2000 | .2953 | .5094 | .8633 | .715 | 69.9 | .852x |
| 80 | 10% | .2208 | .2867 | .4901 | .8735 | .733 | 83.4 | 1.017x |
| 80 | 12% | .2416 | .2806 | .4827 | .8775 | .707 | 95.2 | 1.148x |
| 80 | 15% | .2726 | .2721 | .4715 | .8844 | .684 | 114.3 | 1.390x |
| 96 | 8% | .2227 | .2747 | .4897 | .8741 | .715 | 80.1 | .958x |
| 96 | 10% | .2437 | .2668 | .4698 | .8841 | .721 | 95.8 | 1.154x |
| 96 | 12% | .2647 | .2609 | .4569 | .8910 | .720 | 113.2 | 1.348x |
| 96 | 15% | .2960 | .2514 | .4388 | .9015 | .718 | 126.4 | 1.528x |

The first `r32/p8` wall value includes one-time NumPy/BLAS startup and is not a
steady-state claim. It does not affect the rejection.

The preregistered `r64/h16/p12%` cell passes arithmetic at `c=0.2186`, but:

```text
NRMSE          0.31414  (31.4x the maximum)
p99 row L2     0.53935  (10.8x the maximum)
p01 cosine     0.84469  (minimum 0.995)
sentinel recall 0.67276 (minimum 0.90)
```

Even the highest-quality cell still inside the arithmetic cap,
`r96/h16/p15%` at `c=0.2960`, has NRMSE `0.25144`, p99 `0.43879`, p01 cosine
`0.90155`, and recall `0.71766`. No frozen cell is remotely close. The complete
20-cell sweep took 6.03 seconds and passed `0/20` projection screens.

The registered cell's inclusive NumPy candidate wall was 97.976 ms versus
84.387 ms for the FP32 reference (`1.161x`). Across warmed cells the best
observed ratio was `0.711x`, still far above the note-078 `<=0.30x` M2 target.
Because the numerical M1 kill is already binding, this diagnostic does not
justify implementing a Metal primitive.

## Cleanup and retained evidence

No capture source ships. The root submodule pointer never changed. The M3
helper file was removed, and post-run verification found zero capture helper
references and environment strings in `Qwen35.swift`, plus zero capture strings
in the release binary. The shared M3 source advanced independently after the
capture, so cleanup is asserted by those content checks rather than by claiming
that its final whole-file hash equals the pre-capture hash.

Retained in git:

- `patches/078-e50-runtime-capture.patch`: disposable overlay for the pinned
  `ab73a82` submodule;
- `patches/078-e50-runtime-capture-m3-6a2c.patch`: exact M3-source overlay;
- `probes/activation-residual-contract/`: assembler, probe, frozen sweep, tests;
- `artifacts/e50-layer12-*`: compact benchmark, manifest, sweep, hashes, build,
  hardware, and cleanup evidence.

The raw reproducibility bundle is
`e50_layer12_real_8k_repro.tar.gz`, SHA-256
`4f2c310956bbcdae93185a35c6cee51e2b2e85ab370c4b00e6a7f5c09f3862eb`.
It retains the four raw activation stripes, packed and dequantized weight
tensors, scripts, all 20 result files, logs, and provenance; the assembled
activation is deterministically recreated by `assemble_capture.py`.

## Final gate

**E50 is closed.** Its arithmetic idea remains valid on paper, but the real
layer-12 projection is not contractible in the preregistered budget and the
sentinels do not reliably identify the oracle worst rows. Do not raise rank,
repair rate, or sentinel count post hoc on this capture and relabel the result.
