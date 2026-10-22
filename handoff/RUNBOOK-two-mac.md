# Runbook: two Macs

> Last updated: 2026-10-14

> **Bench/developer only. Product path: `darkbloom cluster`** on each Mac, pick a
> model, done ([two-mac-cluster.md](../docs/provider/two-mac-cluster.md)).

Commands in "Verified" were run here and behaved as described. Commands in
"Not yet verified" come from reading the source and have not completed on two
Macs. Replace placeholders in capitals; never commit real addresses.

## 0. Before anything heavy

One heavy Swift, Metal or GPU job per machine. Check for another workload and
for a loaded provider before building, loading a model, or starting a rank.
Never stop someone else's process to make room.

## 1. Inspect each Mac (read-only) — verified

```sh
sw_vers; sysctl -n hw.model machdep.cpu.brand_string hw.memsize
rdma_ctl status                      # must print: enabled
ibv_devinfo | grep -E "hca_id|state" # one rdma_enN must be PORT_ACTIVE
system_profiler SPThunderboltDataType | grep -E "Device Name|Status|Speed|Receptacle"
```

For the active device `rdma_enN`, the interface `enN` must have an IPv4
address of its own:

```sh
ifconfig enN | grep "inet "                      # must print a line
ifconfig bridge0 | grep member:                  # enN should not be listed
ibv_devinfo -v -d rdma_enN | grep -c "::ffff:"   # must be 1 or more
```

If the port is only a member of the Thunderbolt Bridge, the last command prints
0 and JACCL refuses the device with "No IPv4-mapped GID for this device". The
product sets the port's address itself: `darkbloom cluster` gives the port
Darkbloom's own link service after one macOS approval. Nothing is typed in
System Settings → Network.

## 2. Build the native products — verified on Mac A

```sh
git submodule update --init --recursive
bash scripts/fetch-metallib.sh /ABS/cluster-metal
SHA=$(shasum -a 256 /ABS/cluster-metal/mlx.metallib | cut -d' ' -f1)

bash libs/darkbloom-cluster-worker/build-native-worker.sh \
  "$PWD/libs/darkbloom-cluster-worker" darkbloom-cluster-collective-check \
  /ABS/cluster-metal/mlx.metallib "$SHA"

bash libs/darkbloom-cluster-worker/build-native-worker.sh \
  "$PWD/libs/darkbloom-cluster-worker" darkbloom-cluster-worker \
  /ABS/cluster-metal/mlx.metallib "$SHA"
```

Each prints the binary path. The script fails if the binary holds the JACCL
stub or its Mach-O minimum is not exactly macOS 26.2. The same binary runs on
both Macs (arm64, macOS 26.2 or later); copy it and compare `shasum -a 256`.

## 3. Two-rank transport check — attempted, blocked at step 1 on Mac B

Same `matrix.json` on both Macs; row *i*, column *j* is the device rank *i*
uses to reach rank *j*:

```json
[[null,"rdma_enA"],["rdma_enB",null]]
```

Rank 0 listens on the coordinator address, so start it first, on the Mac whose
firewall accepts the connection:

```sh
JACCL_RANK=0 JACCL_IBV_DEVICES=/ABS/matrix.json JACCL_COORDINATOR=RANK0_LINK_IPV4:PORT \
  ./darkbloom-cluster-collective-check --mode raw --max-mib 64 --deadline-seconds 120
JACCL_RANK=1 JACCL_IBV_DEVICES=/ABS/matrix.json JACCL_COORDINATOR=RANK0_LINK_IPV4:PORT \
  ./darkbloom-cluster-collective-check --mode raw --max-mib 64 --deadline-seconds 120
```

Each rank prints one JSON report and exits 0 only if both saw zero mismatches.
Then repeat with `--mode wrapper`. To show which device carried the bytes,
record the interface byte counters before and after on both Macs
(`netstat -ibn -I enN`) and compare them with the payload volume in the report:
over RDMA the IP counters move by kilobytes while the payload is far larger.

What a failed start looks like (seen here): the rank on the Mac without a GID
exits 1 with the message in section 1; the other rank exits 1 with a coordinator
socket error. Neither hangs and neither leaves a process behind.

## 4. Model artifact — not yet present on either Mac

The runtime accepts exactly the registered Qwen3.5 9B 4-bit artifact (catalog
version `2026-09-03-r1`, 12 files, 6,113,952,230 bytes, aggregate SHA-256
`127de76b4ef82b7aaa0acaac0ee31c784cff066eda64291f521f051469b7c24b`). It must be
a flat directory of real files on each Mac, owned by the user, with no symlink
in any path component. Hugging Face cache snapshots are refused.

## 4b. Pair the two Macs (no SSH) — verified on the pair 2026-10-11

```sh
# On the Mac that will lead (it listens on its Thunderbolt link interface):
darkbloom cluster pair --cluster-id my-pair
#   prints: On the other Mac run:  darkbloom cluster pair --connect <its link address>
# On the other Mac (it only dials):
darkbloom cluster pair --connect <address the first Mac printed>
```

Both screens show the other Mac's attested chip, macOS and security posture and
the same six-digit code; type `y` on each Mac when the codes match (`n` if not).
Each Mac then pins the other's Secure Enclave key (the key its attestation is
signed with), both countersign the cluster roster the coordinator registers
(registration v3), and both store the key of their link control channel, in
owner-only files under `~/.darkbloom/cluster-pairing/`. A code is valid for 10
minutes; three failed pairings lock pairing out for 10 minutes. `darkbloom
cluster pair --status [--json]` lists the pairings (public values only);
`--forget PIN` unpairs. A saved roster registration starts only when every
other member in it is a key this Mac pinned. The setup wizard's step 3 runs the
same ceremony (`l` listens, `c` connects). A debug build without the signed
build's keychain entitlement needs `DARKBLOOM_DEBUG_SE_KEY_FILE` so its key
(and so the pin) survives a restart.

## 5. Saved setup and serving (developer-only) — not yet verified end to end

Developer-only: `darkbloom cluster` saves and syncs the setup and starts both
Macs itself. `cluster configure` and `start --local --distributed` below are
the manual developer route.

```sh
# On each Mac: capability metadata from the installed worker.
darkbloom-cluster-worker --describe-runtime --config MODEL/config.json \
  --manifest MODEL/manifest.json --expected-executable-sha256 WORKER_SHA256 > capability.json

# On each Mac: validate and save the cluster setup.
darkbloom cluster configure --input /ABS/cluster.json \
  --capability /ABS/capability.json --capability-sha256 CAPABILITY_SHA256
darkbloom cluster doctor

# On the leader only.
darkbloom start --local --distributed
darkbloom cluster status
```

`--describe-runtime` is verified against fixtures. The rest is known to be
incomplete in this revision; see [DESIGN-gap-map.md](DESIGN-gap-map.md) before
trying it.

## 6. Stopping

Stop the leader with an interrupt or `darkbloom stop`, and let the owners fence
and reap their workers. Do not send SIGKILL to a worker that has a model
loaded. After a stop, confirm on both Macs that no `darkbloom-cluster-worker`
remains and that wired memory has returned to its earlier level before starting
again.
