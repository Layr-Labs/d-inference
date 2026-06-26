# JACCL (RDMA-over-Thunderbolt) — Readiness & Enablement Hand-off

**Status: BLOCKED on this hardware pair (TB4 base M4).** Update (verified
2026-06): RDMA was enabled on both Macs (`rdma_ctl enable` from Recovery OS,
`status` = enabled on both), but **only the M4 Pro exposes RDMA devices; the base
M4 exposes zero**, because Apple's Thunderbolt RDMA requires **TB5** and the base
M4 only has TB4. JACCL needs RDMA devices on *both* ends, so it cannot run on the
M4 + M4 Pro pair. See "Hardware finding" below. The software side remains ready —
a pair of TB5 machines (M4 Pro/Max or better, both ends) would work.

## Hardware finding (the real blocker)

| Node | Chip | Thunderbolt | `rdma_ctl status` | RDMA devices (`ibv_get_device_list`) |
|------|------|-------------|-------------------|--------------------------------------|
| mac-24 | M4 **Pro** | **TB5** (up to 120 Gb/s) | enabled | **3** (`rdma_en1/2/3`) |
| mac-32 | M4 (base) | **TB4** (up to 40 Gb/s) | enabled | **0** |

Both were rebooted after enabling; the asymmetry persists. The base M4's TB4
controller has no RDMA device for `librdma` to bind to — `rdma_ctl` flips the
persistent setting but there is no TB5 hardware to attach to.

**Confirmed by the primary source** — MLX distributed docs
(https://ml-explore.github.io/mlx/build/html/usage/distributed.html):
> "Starting from macOS 26.2, RDMA over thunderbolt is available and enables
> low-latency communication between Macs with **thunderbolt 5**."

The same page notes RDMA must be enabled in recovery mode ("cannot be done
remotely even with sudo"), verified via `ibv_devices` listing `rdma_enX`, and
that JACCL requires a fully-connected (direct TB cable) topology. Our empirical
result (M4 Pro/TB5 → 3 devices; base M4/TB4 → 0) matches the doc exactly.

**Conclusion: JACCL is a TB5-on-both-ends feature; not viable on the M4 + M4 Pro
pair (base M4 is TB4).** The TCP ring (what we benchmarked) remains the only
cross-machine transport here. Two TB5 Macs (e.g. M3 Ultra per the doc's example,
or M4 Pro/Max on both ends) would unlock it.

---

(Original readiness notes below — software prerequisites are all met; only the
TB5 hardware requirement is unsatisfied on the base M4.)

## Why JACCL matters

The tensor-parallelism comms floor we measured (`comms-bench`: **83.35 ms/token,
1.04 ms/reduce, ~12 tok/s TP ceiling** on 2× M4 over Thunderbolt-IP) is dominated
by the **CPU-stream collectives + GPU↔CPU↔socket round-trip** — the ring backend
forces `Device::cpu` (`ring.cpp:471`) and copies the tensor across the GPU↔CPU
boundary every hop. JACCL is RDMA-over-Thunderbolt: zero-copy, OS-bypass transfer
that attacks exactly that round-trip. It is the most direct route to making
batch-1 tensor parallelism viable (vs. only winning on batched throughput).

It is **not** blocked by the trust policy — the coordinator accepts
`rdma_disabled: false` providers under a registered-buffer RDMA policy
(`api/provider.go:1184-1200`); the security boundary is the signed runtime's
IOMMU buffer-registration discipline, not a blanket ban.

## Verified prerequisites (all ✅ except the last)

| Prerequisite | Status | How verified |
|---|---|---|
| macOS 26.2+ (JACCL min) | ✅ 26.5.1 | `sw_vers` on mac-24 |
| TB5 hardware + `rdma_ctl` | ✅ | `/usr/bin/rdma_ctl` present (root-owned); `system_profiler SPThunderboltDataType` shows "Up to 120 Gb/s" |
| `librdma.dylib` loadable | ✅ | `dlopen("librdma.dylib", RTLD_NOW)` succeeds (probe) |
| JACCL backend compiled into fork | ✅ | `libs/mlx-swift/Package.swift:199-200` excludes the `no_jaccl.cpp` stub and builds the real `jaccl.cpp`; `distributed.cpp:105-123` wires `is_available("jaccl")` |
| `MLXDistributedBackend.jaccl` exists | ✅ | `provider-swift/.../Cluster/MLXDistributed.swift:42` |
| Trust policy permits RDMA | ✅ | `coordinator/api/provider.go:1184-1200` (accepts + logs, only requires reporting) |
| **RDMA actually enabled** | ❌ **gated** | `rdma_ctl status` → `disabled`; `rdma_ctl enable` → *"This tool needs to be executed from Recovery OS."*; `ibv_get_device_list` returns **0 devices** while disabled |

## The blocker: enable RDMA from Recovery OS (both Macs)

`rdma_ctl enable` refuses to run from normal macOS — it must run in Recovery OS
(this ties to the MDM `MDMRecoveryLocked` check, `mdm/mdm.go:245`: Recovery Lock
blocks `rdma_ctl enable`). Steps, on **each** node:

1. Shut down. Apple Silicon: hold the power button until "Loading startup options"
   → **Options** → Continue (Recovery OS).
2. Utilities → Terminal: `rdma_ctl enable`
3. Reboot to macOS. Verify: `rdma_ctl status` → `enabled`, and the `ibv_get_device_list`
   probe returns ≥1 device.

Both Macs must have RDMA enabled, and the **direct Thunderbolt cable** must show a
linked device (`system_profiler SPThunderboltDataType` should show a connected
device, not "No device connected" as it did during this session).

## What's left to wire (once RDMA is enabled)

JACCL init reads three env vars (`jaccl.cpp:131-141`) instead of the ring's
hostfile:
- `MLX_RANK` — this node's rank (already derived from config member order)
- `MLX_JACCL_COORDINATOR` — `ip:port` of the rank-0 coordinator socket
- `MLX_IBV_DEVICES` — a JSON **device connectivity file**: an array-of-arrays
  giving, for each rank, the RDMA device name(s) to reach every other rank
  (`DeviceFile`, `jaccl.cpp:18-58`). Device names come from `ibv_get_device_list`
  once RDMA is enabled.

Implementation sketch (mirrors `MLXRingEnvironment`):
1. Add `MLXJacclEnvironment.materialize(plan:)` that writes the device file +
   returns `{MLX_RANK, MLX_JACCL_COORDINATOR, MLX_IBV_DEVICES}`.
2. In `ClusterHeadBringup.bringUp`, branch on `plan.backend`: `.ring` →
   existing path; `.jaccl` → the new env, then `MLXDistributedGroup.initialize(backend: .jaccl)`.
3. Set `backend = "jaccl"` in both nodes' `[cluster]` config.
4. The decode loops (`ClusterPipeline`, `ClusterBatchPipeline`, the batched
   scheduler/server) are transport-agnostic — they call `group.send/recvLike/
   allGather`, which dispatch on the initialized backend. **No decode-loop
   changes needed.** The one thing to check: whether JACCL collectives run off
   the CPU stream (the whole point) — confirm `communication_stream` for jaccl
   does not force `Device::cpu`. If it still does, the GPU↔CPU round-trip
   remains and the win is smaller; measure with `comms-bench` first.

## Validation plan (when enabled)

1. Re-run `comms-bench 5120 40 64` over JACCL vs the ring baseline (83 ms/token).
   Target: per-reduce well under 1 ms and a TP ceiling far above ~12 tok/s.
2. If the floor drops enough, build the tensor-parallel decode path
   (`docs/architecture/cluster-tensor-expert-parallel.md`) — JACCL is the
   transport that makes batch-1 TP worth doing.

## Session note

Probed on mac-24 (M4 Pro, macOS 26.5.1, TB5). `librdma.dylib` loads but
`ibv_get_device_list` → 0 devices because `rdma_ctl status` = disabled. TB buses
showed "No device connected" during the session (the 169.254 link we used for the
ring is Thunderbolt-IP/bridge networking, a different layer than the raw TB device
link RDMA needs). Parking here until the Recovery-OS enable is done on both Macs.
