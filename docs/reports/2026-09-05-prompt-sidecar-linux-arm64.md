# Prompt sidecar under the Linux address-space limit

> Last updated: 2026-09-05 · commit `5d29819d9`

The tokenizer-sharing sidecar passed a local native ARM Linux check with its
hard 1 GiB address-space limit enabled. All 96 cold and 375 warm requests
produced exact plans across the 98-vector corpus, with zero errors, timeouts
or child restarts. This is a Linux/musl diagnostic; production Linux/amd64 CI
remains required.

## Environment and provenance

The source is the banked tokenizer milestone `544cfa5ee`, extracted from Git
into a private directory. The parent reverified its 51 captured tokenizer and
proof source paths, plus module/lockfile bytes, before archiving this result.
The six exact renderer-v3 contracts share three tokenizer digests. All 48
offline artifact/fixture files were hash-verified inside the guest.

Lima 2.2.0 ran an Alpine 3.23.4 aarch64 guest through macOS virtualization,
with four CPUs, 4 GiB RAM and no host directory mounts. Rust and Cargo 1.88.0
components were verified against the pinned official release manifest. The
sidecar was built with `--locked --release --target aarch64-unknown-linux-musl`;
`file` confirmed a static ELF executable. The identical proof source was
cross-compiled with Go 1.25.0, `GOOS=linux GOARCH=arm64 CGO_ENABLED=0`.

Sidecar binary SHA-256:
`3137e7f913a435e6899262a8e650b34fe7241326226736b4f4c843f43db85236`.
The [evidence manifest](evidence/prompt-sidecar-linux-arm64-2026-09-05/manifest.json)
includes the proof binary hash, source archive identity, guest image digest,
toolchain component hashes, commands, build logs, raw results and observed
process limits. Binaries and VM disks are retained outside the repository.

## Result

The proof retained the existing 25 QPS, 15-second, 1024 MiB RSS and 128 MiB
growth gates. A separate observer read `/proc` every 100 ms and confirmed both
actual sidecar children had soft and hard `RLIMIT_AS` set to 1,073,741,824 bytes.
The VM was stopped after evidence capture.

| Measurement | Observed |
|---|---:|
| Cold requests, exact | 96 / 96 |
| Warm requests, exact | 375 / 375 |
| Warm vectors covered | 98 / 98 |
| Achieved request-start QPS | 24.9951 |
| Maximum scheduling lag | 6 ms |
| Cold peak RSS, proof sampler | 444.56 MiB |
| Second process peak RSS including preload, proof sampler | 445.30 MiB |
| Warm traffic peak RSS, proof sampler | 159.20 MiB |
| Warm growth after preload, proof sampler | 2.34 MiB |
| Warm planning mean | 3.305 ms |

The proof samples RSS every 25 ms; the separate `/proc/status` observer saw
up to 458.48 MiB RSS and 482.36 MiB virtual size. Different sampled peaks are
preserved rather than treated as exhaustive maxima. All observations stayed
below the unchanged limits. The planning mean is cumulative microseconds
divided by request count; histogram buckets do not establish exact quantiles.

This was one quiet local run with uncontrolled filesystem cache state. The
guest CPU allocation, allocator and operating system differ from the prior
macOS comparison, so these numbers do not measure an additional speedup or
memory reduction against that run. Native Linux/amd64, sustained production
traffic and end-to-end model serving remain separate checks. The repository's
production check is `scripts/verify-prompt-sidecar-linux.sh`; this diagnostic
used the same proof command with its offline verified artifact-root option.
