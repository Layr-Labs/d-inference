# Link setup v2: the cluster port belongs to the cluster alone

Status: built and checked without privileges, dry-run on both Macs; never applied.
Code: `provider-swift/Sources/ProviderCore/Inference/Distributed/Diagnostics/Link/ClusterLinkIsolation*.swift`,
`ClusterLinkNetworkFacts.swift`, `ClusterLinkClusterAddress.swift`, `ClusterLinkLaunchReadiness.swift`.
Gap: A7 in [DESIGN-gap-map.md](DESIGN-gap-map.md).

## What went wrong with the first version

The owner, 2026-10-09: the cable link "should be something we have fixed in the
clustering setup procedure"; ThunderMLX, exo and the owner's oMLX clustering
never had the problem. What was read on the two Macs that day (read-only,
masked captures in `evidence/link-v2-20261009/captures`):

- Mac B has macOS Internet Sharing on since December 2025: Wi-Fi shared over the
  Thunderbolt Bridge (`bridge0`, members `en1 en6 en2`, `bootpd` and `natpmpd`
  running). Its device list (`com.apple.nat` `NAT.SharingDevices`) names
  `bridge0` and also `en6`, the cluster port, directly.
- The cluster port `en6` is a `bridge0` member. The first version gave it a
  link-local alias and a root job that re-adds the alias every 10 s. Twice that
  day the alias was stripped mid-session (most likely Internet Sharing
  reshaping the bridge) and runs starting in the gap failed with JACCL's
  "No IPv4-mapped GID".
- Mac A's cable port `en7` has a DHCP service, so it takes a lease from Mac B's
  Internet Sharing: a second default route through the cable (behind Wi-Fi), a
  scoped DNS resolver through the cable (IPv4 and router-advertised IPv6), and
  the "bridged Ethernet" and internet warning the owner sees in the menu bar.
- The pair's TCP traffic (the JACCL coordinator socket, SSH over the cable)
  used Internet Sharing's DHCP subnet. The first version's link-local
  addresses could not carry it: macOS gives the primary interface (Wi-Fi) the
  unscoped `169.254/16` route on both Macs (`netstat -rn` in the captures), so
  a connection to the other Mac's link-local address leaves through Wi-Fi.

## What the owner's other tools do

- exo (`research/exo/tmp/set_rdma_network_config.sh`, the app's
  `NetworkSetupHelper`): removes every `bridge0` member and the bridge itself
  (also from the network preferences), creates and switches to a network
  location of its own with one DHCP service per Thunderbolt port (link-local
  when no server answers), disables the Thunderbolt Bridge service, and runs
  all of it as a root launchd job at load and every 30 minutes. Uninstall
  switches back to Automatic and deletes the location.
- ThunderMLX (`docs/SETUP.md`): a manual IPv4 per link on a private subnet
  (`10.0.0.1`/`10.0.0.2`), no router. Mac A still carries this as a service on
  `en5`.
- oMLX (`omlx/cluster/transport.py`): treats `169.254/16` as unroutable, takes a
  link only when both ends share a subnet over the selected interfaces, and
  proves the route with `route -n get` and a ping in both directions.
- MLX's own `mlx.distributed_config`: `ifconfig bridge0 down`, then an address
  per port and a host route; nothing persists.

The common pattern: the port is out of the bridge, it has a fixed address in a
subnet nothing else uses, no router, and macOS (not a helper) keeps it.

## The end state, and why each part

For the active cluster port `P` with hardware port `H`:

1. `P` is in no bridge. Internet Sharing over the bridge's other members goes
   on as before; the bridge, its service and the other members are untouched.
2. `P` has one network service of Darkbloom's, `Darkbloom Cluster Link (P)`:
   manual IPv4 `10.219.x.y/16`, no router, no DNS, IPv6 link-local only. macOS
   applies and keeps it, also after a restart and a cable replug; no
   Darkbloom process or job runs.
3. Any other enabled service on `P` is switched off with its settings kept.
4. What the first version left on `P` goes: its keeper job and file, and its
   link-local alias.

Address: `10.219.<third>.<fourth>/16`, where the two octets are the ones the
first version derives from the Mac's hardware UUID and the interface name, so
both ends of a cable choose without talking (a collision is about 1 in 64,500)
and a port keeps its host part. A private /16 gets an ordinary interface route
through `P` on both Macs, which `169.254/16` does not. If anything else on the
Mac already uses `10.219/16` (another interface, a VPN route) Darkbloom stops
before any prompt (`clusterSubnetInUse`).

Not done, deliberately:

- No network location switch (exo): it would drop every other setting the
  owner has in Automatic, and its undo is coarse.
- The Thunderbolt Bridge is not destroyed and not disabled; only `P` leaves it.
- Internet Sharing is never changed. It is the owner's setting, and the change
  would need a restart of a system daemon whose behaviour Darkbloom cannot test
  without privileges. When Internet Sharing lists `P` itself among its devices
  (Mac B today), taking `P` out of the bridge would not make sharing harmless:
  Internet Sharing makes its own bridge (`bridge100`) for directly listed
  devices and would serve addresses on `P` again. So that finding
  (`internetSharingToPort`) stops the change before any prompt and says what
  the owner can do: in System Settings → General → Sharing → Internet Sharing
  ⓘ, turn off “Thunderbolt 2” (en6) under “To devices using”, or turn
  Internet Sharing off. Sharing over `bridge0` may stay on; once `P` is out of
  the bridge it no longer reaches the cable.
- The first version's keeper is not kept as a safety net. With its own service
  outside every bridge, macOS owns the port's address; a job re-adding an
  alias would only matter if the port went back into a bridge, and then the
  doctor names it (`portInBridge`) and the launch wait below bounds the damage.
  This keeps the one approval to persistent settings only, like ThunderMLX and
  oMLX, and unlike exo's periodic root job.

## Detection, without privileges

Read by `darkbloom cluster link` (also `--json`), `darkbloom cluster doctor`
(check `localLinkIsolation.<device>`), the guided `darkbloom cluster` and the
console, for every active port. Finding names are an output contract.

| Finding | Read from | What the one approval does |
|---|---|---|
| `portInBridge` | `plutil -extract VirtualNetworkInterfaces.Bridge json` of the network preferences | takes `P` out of that bridge for good |
| `internetSharingOverPortBridge` | `com.apple.nat` `NAT.Enabled` and `NAT.SharingDevices` name that bridge | the same; sharing over the remaining members is left alone |
| `internetSharingToPort` | `NAT.SharingDevices` names `P` itself | nothing: blocks, owner turns `P` off under Internet Sharing |
| `portInUnmanagedBridge` | `ifconfig -a` lists `P` in a bridge the preferences do not have (Internet Sharing's own) | nothing: blocks, same owner step |
| `defaultRouteViaPort` | `netstat -rn -f inet`, any `default` row through `P` | own service without a router |
| `dnsViaPort` | `scutil --dns`, a resolver with name servers reached through `P` | own service without DNS, IPv6 link-local only |
| `dhcpLeaseOnPort` | `ipconfig getpacket P` returns a DHCP reply | own service with a fixed address; DHCP service off |
| `portAddressMissing` | `ifconfig -a`, no `inet` on `P` | own service with a fixed address |
| `clusterServiceMissing` / `clusterServiceMisconfigured` | `networksetup -listnetworkserviceorder`, `networksetup -getinfo` (manual, cluster address on record, `255.255.0.0`, no router, IPv6 not automatic) | the service is made (afresh) |
| `otherServiceOnPort` | `-listnetworkserviceorder`, another enabled service on `P` | switched off, settings kept |
| `clusterSubnetInUse` | another interface's `inet` or another interface's route in `10.219/16` | nothing: blocks |
| `serviceNameUnsafe` | a service or hardware port name outside letters, digits, spaces and `( ) - . _` | nothing: blocks (rename it) |
| `hardwarePortUnknown` | `networksetup -listallhardwareports` has no port for `P` | nothing: blocks |
| `stateUnreadable` | a reading timed out, overflowed or was garbled | nothing: blocks |

Reports keep names and verdicts only: no address, no service name, no bridge
member list. The doctor fails the isolation check for the port serving would
use, ready or not, because a port that is not isolated can lose its address
mid-session; elsewhere it is `notObserved`.

Observed on 2026-10-09: Mac A `defaultRouteViaPort, dnsViaPort,
dhcpLeaseOnPort, clusterServiceMissing, otherServiceOnPort` (no blocker); Mac
B `portInBridge, internetSharingOverPortBridge, internetSharingToPort,
clusterServiceMissing` (blocked by `internetSharingToPort`).

## The one approval

`darkbloom cluster` (or `darkbloom cluster link --fix`) runs one fixed command
line through `osascript … with administrator privileges`, so macOS shows its
own prompt once; Darkbloom never uses `sudo` and never sees a password. The
commands run under `set -e`; the few that only tidy what may already be gone
end in `|| true`. Order and reasons:

1. First-version keeper, when installed: `launchctl bootout system/io.darkbloom.cluster-link.P`, `rm -f` its plist; then its alias `ifconfig P inet 169.254.x.y -alias`.
2. When `P` is in a bridge `B` at position `i` of the preferences:
   `PlistBuddy -c 'Print :VirtualNetworkInterfaces:Bridge:B:Interfaces:i' preferences.plist | grep -qx P`
   (a list that changed since it was read stops everything), then
   `PlistBuddy -c 'Delete …:i' preferences.plist`, then `ifconfig B deletem P`.
   `scutil --prefs` was tried on a scratch copy and rejected: its `get` loses
   the bridge's `Options` (`__AUTO__ = thunderbolt-bridge`) and its `commit`
   failed. PlistBuddy on a scratch copy deletes exactly the member, refuses a
   stale index, and its `Add` at the same index restores byte-identical XML.
3. `networksetup -createnetworkservice 'Darkbloom Cluster Link (P)' 'H'`,
   `-setmanual … 10.219.x.y 255.255.0.0` (no router), `-setdnsservers … Empty`,
   `-setv6LinkLocal …`. These commit and apply the network preferences, which
   also applies step 2, and give `P` an owner that keeps the address. When the
   service already exists it is removed first and made afresh.
4. `networksetup -setnetworkserviceenabled '<other service on P>' off` for each.

Before the prompt an owner-only record (`~/.darkbloom/cluster-device/link-isolation.json`,
mode 0600, schema `darkbloom_cluster_link_isolation_v1`) stores the address,
the hardware port, the bridge and position, and the services switched off.
After the approval the port is read again for up to 15 s: it must be `ready`
and have no finding, or the outcome says what still holds
(`appliedButNotIsolated`). A declined or failed first attempt that changed
nothing leaves no record.

Exact commands for the two Macs are in `evidence/link-v2-20261009/dry-run`.

## `darkbloom cluster link --remove`

Restores what the approval changed, from the record and from what is found
now, under one approval: `PlistBuddy -c 'Add …:i string P'` (position clamped
to the bridge's current length, only when `P` is not back), `networksetup
-removenetworkservice 'Darkbloom Cluster Link (P)'`, `-setnetworkserviceenabled
'<service>' on` for each service it switched off that is still off,
`ifconfig P inet 10.219.x.y -alias` only for an address left without its
service, and `ifconfig B addm P`. Every command runs; what is found afterwards
decides `removed`. A service of Darkbloom's without a record is removed by its
name and nothing else is guessed. The first version's alias and keeper are not
put back: the restored state is the one before Darkbloom touched the port.

## Before a rank starts

`cluster worker-owner --stdio` (both ranks, leader-local and follower) waits up
to 20 s (`ClusterLinkLaunchReadiness.waitSeconds`) for the saved setup's RDMA
device to publish its IPv4-mapped GID, reading local state once a second
without the network settings. Ready: launch. RDMA off or missing: refuse at
once. Port without address or GID, or no active port, after 20 s: refuse with
the state and its guidance. A reading that fails, or a device this Mac does not
list, cannot prove the link unusable: after 20 s the launch goes ahead and
JACCL decides.

## What changes for the pair

- The JACCL coordinator address and SSH over the cable move to the `10.219`
  addresses: `ipconfig getifaddr <port>` returns the new address on each Mac.
  Mac B's `bridge0` address no longer reaches Mac A over the cable.
- Both Macs need the change for TCP over the cable; between the two approvals
  the cable carries no common subnet. Mac B first (it removes the DHCP server
  from the cable), then Mac A.

## Not shown

- Nothing here has run with privileges. In particular not observed: that
  `networksetup -setmanual` accepts the three-argument form (no router) — the
  owner's own router-less manual services show `Router: (null)`, which suggests
  it does; what `networksetup -getinfo` prints for link-local IPv6 (any value
  other than `automatic` is accepted); and whether macOS, at the next restart,
  puts a Thunderbolt port that has its own service back into the automatic
  Thunderbolt Bridge (the owner's Mac A, with per-port services and no bridge,
  suggests it does not). The verification after the owner's approvals, and
  again after the next restart, settles these.
- Whether Internet Sharing, with `bridge0` still shared and `en6` no longer
  listed, leaves `en6` alone over days.
