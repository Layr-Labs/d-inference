# Sandbox performance evidence

`../Scripts/benchmark-sandbox.py` compiles `cpu.c` once, uploads the exact binary
through the consumer CLI, verifies its SHA-256 inside the VM, and compares
matching checksums before reporting timings. It runs one warmup per side and
20 alternating host-first/guest-first pairs by default. Per-process execution
seconds and total consumer API wall time are separate measurements.

Run on the physical Mac that owns a ready non-production sandbox. Keep its
resource allocation and other host work recorded alongside the result; this
script does not stop providers, alter scheduling, or establish an idle host.
The sandbox lease must cover the full campaign.

```sh
DARKBLOOM_API_URL=https://your-nonproduction-coordinator \
DARKBLOOM_API_KEY=... \
python3 sandbox-macos/Scripts/benchmark-sandbox.py \
  --cli /absolute/darkbloom-sandbox --sandbox SANDBOX_UUID \
  --output /absolute/new/measurements --pairs 20 --workers 4
```

Use existing environment-based credentials; do not put a real key in a saved
command or evidence file. `--allow-insecure-localhost` permits an explicitly
selected loopback test coordinator. `--host-only` exercises the native workload
without a sandbox and records that no VM measurement occurred. Short workloads
are useful for checking the harness; raise iterations until execution lasts at
least 250 ms before interpreting performance.

The evidence retains compiler version, source/binary/CLI hashes, every complete
pair, command IDs, parameters and errors. A deterministic integer recurrence is
a CPU microbenchmark. It does not measure CI builds, cold boot, disk workloads,
networking, inference coexistence or two-VM contention; those require separately
specified workloads and physical evidence. No performance threshold or release
readiness is inferred from a successful run.
