# Standalone authenticated RDMA component benchmark — 2026-09-20

This is a private lab executable and physical harness. It measures the existing AES-GCM/HKDF record codec, completed native copies and two-host RDMA. It creates no Darkbloom membership, attestation, runtime approval, request owner or serving capability. It does not change any existing crypto, native copy, JACCL, Provider or coordinator source. MAIN and all previous candidates remain unchanged.

The native source is independently frozen by `native-manifest.json` (98a051061c971046901b913ff20f86fb81642f5f6c6714ba9baf4ac68409f591). `overlay.json` has six Runtime additions, one thin executable entry and one Package replacement. The preferred exact base is the qualified protected native7 workspace in `context.json`; its source snapshot has 3,081 files and the proposal has 3,088, with the same 9,832 dependency files. The older Gemma cache lacks these exact record/copy adapters. Preserve the old workspace evidence and binaries; apply to a private cached successor, using the separately prepared `cluster-lab-encrypted-rdma-build-20260920` build wrapper. No author compiler, native, fixture or physical execution is claimed.

`AGENTS.md` is pinned in `context.json`. The implementation follows its small-module and lifecycle requirements. This task does not change product routing/state, deployed infrastructure, signing, or protocol records.

## Scope and authentication

`LabRecordJob` admits only `ssh_host_key_lab_only`, two ranks, a fresh public run UUID, exact two host-key digests, native/source/MLX digests, actual hardware/OS strings and a public commitment to a fresh random 32-byte secret. Rank is excluded from the common transcript but determines HKDF direction. The unchanged record codec binds the lab transcript, context and limits; its external-authority constructor does not establish product membership. No `NativeAuthorizationStart`, fake certificate, coordinator grant or product protected-profile constructor is used.

The root harness generates one new secret per payload job with `os.urandom`. Its local and temporary remote files are owned regular 0600 files inside canonical 0700 directories. Pinned ed25519 SSH delivers the secret on stdin, never in argv, environment, JSON, progress, receipts or a worker input log. The remote same-PID native gate opens and validates the one-shot file, unlinks it, then installs its already-open descriptor as native FD0. Core dumps are disabled by both Python owners and inherited by native exec. Native reads exactly 32 bytes plus EOF, checks the commitment and closes FD0. Buffers are wiped where practical; there is no claim of immediate erasure of all Python, Swift or CryptoKit internal copies. Process retirement closes the remaining lifetime.

Before payload measurements, both ranks exchange an authenticated 32-byte confirmation of the common public scope. Actual returned frame digests must join across ranks in both directions for every raw/encrypted transfer. Every decrypted payload and native-array roundtrip must equal its expected fixture bytes. Counter, context, size or integrity failure aborts; there is no fallback. This establishes an SSH-authenticated lab component measurement, not a verified Darkbloom pair or forward-secret product session.

## What is measured

Each fresh process handles one selected payload size, three warmups and twenty measured iterations per mode. Allowed byte sizes are `1, 5632, 8192, 10240, 65536, 131072, 360448, 720896, 1048576, 4194304, 5242880`. These cover small messages and representative residual/chunk byte counts; they do not authorize a model workload. For example, 360,448 and 720,896 bytes equal 64 and 128 rows of 2,816 BF16 values. The array view is uint8, so this measures unchanged bytes and copy paths, not BF16 arithmetic.

Modes run in this fixed order:

| Mode | Logical bytes per direction | Measured path |
|---|---:|---|
| `raw_payload` | P | Existing completed Data/native/RDMA path |
| `raw_record_size` | P + 40 | Same raw path with deterministic padding to the encrypted record size |
| `encrypted_record` | P + 40 | Actual record seal, completed byte transport and authenticated open |
| `encrypted_array` | P + 40 | Actual native-array export, record path and authenticated native-array import |

The padded raw mode is not pre-encrypted ciphertext. All four modes include the original checking/fencing/copy behavior; the raw modes transfer public fixture bytes only. Each rank separately records 23 local codec seal/open samples and 23 completed native export/import samples. Array construction before a transfer and verification/hashing after it are excluded from that transfer timer. CPU codec equality checks are outside the codec interval. Independent component medians must not be summed or subtracted to claim a directly measured end-to-end decomposition.

Rank0 roundtrip and both operation intervals use one local monotonic clock. Rank1 receive includes peer wait; no cross-host clock subtraction is performed. The fixed mode order and retained after-timer verification can affect cache state and the next iteration. Keep all raw samples, describe this ordering, and repeat as needed before making a calibration claim. No throughput, model TPS, TTFT, encryption bottleneck or theoretical speedup is asserted by source alone.

Logical record overhead is 40 bytes. Actual JACCL posted-buffer padding is separate: this exact source uses fixed 4 KiB frames on macOS 26.2 and size-dependent buffers on later supported systems. The existing zero-tail staging fix is bound by `context.json`; the report's logical frame sizes are not a physical link-byte counter. Actual OS and native/MLX identities must remain attached to any primitive calibration.

## Resources and ownership

There is one existing raw Collective per rank and one shared encrypted codec/counter pair for confirmation and both encrypted modes. The wire limits are 64 records per direction; successful runs must account for exactly 47 records and `46*P + 32` plaintext bytes per direction. Local CPU fixtures use separate rank-specific binding domains, so their key/nonce spaces do not overlap with the wire or each other.

Native has a 120-second alarm and a 115-second retained work deadline; the remote owner has 135 seconds and root SSH 165 seconds. Native checks AC/thermal, pressure1, zero swap and actual free memory. It retains a full 512 MiB process allowance above the 6 GiB free floor: minimum actual free is **6,979,321,856 bytes**. Native allocation/peak is bounded to baseline + **268,435,456 bytes** (256 MiB); process lifetime footprint is bounded to baseline + **536,870,912 bytes** (512 MiB). These are model-free experimental ceilings, not a newly qualified serving profile. No reserve is reduced from current or sampled usage.

The copied canonical gate holds the original device flock through same-PID exec and never writes or clears the journal. The reused owner preserves original process-group cleanup, complete output/EOF handling and natural-exit verification. The native scope invalidates the codec, releases the same Collective, synchronizes and requires exact baseline MLX active memory/cache0. Native JSON explicitly cannot establish process/lease retirement. The parent requires exit0, complete output, both original groups absent, empty journals/process observations, secret-file absence, strict returned-report joins, and alias restoration. Peer failure cancels the other matching job. Alias release requires both quiescence observations; its original independent 600-second expiry remains a failure fallback, not success. No remote process is killed based on an unrelated discovered identity.

## Actual build and activation

Source check only:

```sh
python3 -B check_sources.py
```

The sibling build wrapper owns the actual bounded compile and six metadata command groups. `--check-local` checks eight CPU contracts with a clearly public fixture key. `metadata-job.json` is a public metadata-only fixture; its placeholder hardware and secret commitment cannot pass execution. Wrong identity, size and rank must be refused. Compilation uses product `LabAuthenticatedRDMABenchmark`, jobs2 and the existing `arm64-apple-macosx26.2` flags. The same exact source produces the measured executable; no separately compiled stand-in is accepted.

Before activation, `build_binding.py --actual /absolute/path/to/actual-bindings.json` requires actual successful build/metadata receipts, the complete exact source and dependency inventories, actual binary/resource bytes and read-only pinned-SSH host observations. See `activation-contract.json` for fields. It creates `artifact-bindings.json` exclusively and refuses absent/mismatched evidence. This package contains no actual lab binary hash or hardware result. Signing and product attestation are intentionally absent because the endpoint remains explicitly lab-only; that absence must never be recast as product trust qualification.

After root review and its explicit physical/compiler slot, run the six Python controls through the existing owned helper with regular stdout/stderr files and a 30-second bound:

```sh
python3 -B -m unittest discover -s Tests -p test_contract.py -v
```

Those controls use fabricated reports and a local public-fixture stdin child. They are not measurements or remote admission. Bind their actual receipt separately.

After actual binding, root can use the following commands under its existing owned supervisor. Deployment is create-only and refuses an existing remote namespace. The root physical command needs an outer 1,100-second ceiling to cover the independent alias fallback plus two bounded collections; normal native work remains 120 seconds.

```sh
python3 -B deploy.py prepare
python3 -B deploy.py install --host darkbloom-24
python3 -B deploy.py install --host darkbloom-48
python3 -B run_case.py prepare --name p10240-1 --payload 10240
python3 -B run_case.py pair --name p10240-1
```

Use a fresh name and secret for every additional payload/repetition. Never copy `private-secrets` into a package or evidence directory. Collection is limited to public run directories and the input transcript must be empty. A preparation failure before launch may preserve an unused 0600 local secret; it cannot produce a successful physical receipt. Failure logs and directories remain, and success cannot be obtained by overwriting them.

`harness-lineage.json` names the reused 93c expert supervisor files and marks which copies are exact. Changes are confined to the lab namespace/product/job/result contract, fresh-secret stdin adapter, deadlines, disabled core dumps and stricter result joins. `manifest.json` binds all source and metadata, including the independently frozen native manifest. The actual activation, deployment and run outputs are additive and are not fabricated members of this source freeze.
