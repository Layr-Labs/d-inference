# Callback bootstrap, IPv4 and the closed mesh relay

The owner callback removes native TCP bootstrap addressing from the selected JACCL initialization path. It does **not** remove the selected RDMA device's IPv4-mapped GID requirement. No interface, environment, gate or source changes were made for this note, and no live interface/device/GID, native process or candidate output was inspected.

## Two independent uses of IP

`jaccl/lib/jaccl/jaccl.cpp:207–223` chooses the supplied factory before the TCPAllGather fallback. The callback overload at 261–276 installs that factory before Config validation; Config::is_valid at 177–180 accepts a factory instead of a nonempty coordinator. Thus the selected callback route does not create the TCPAllGather listener/connect in rdma.cpp:327 onward or tcp.cpp:90–118. The prerequisite fresh-factory check refuses an already cached JACCL group; it does not authenticate an earlier plaintext group.

The resident facade intentionally preserves stricter existing configuration checks. `QwenResidentJACCLConfiguration.swift:79–108` rejects ring overrides and still requires a canonical bounded unicast IPv4 coordinator string with a valid port. Lines 25–38 retain that string in the cross-rank configuration fingerprint; 48–56 recheck the environment and raw device matrix. This is syntax/configuration binding, not a test that the coordinator address is assigned to a local interface. No relaxed callback-specific configuration path is proposed here. The nil callback path remains legacy experimental TCP bootstrap and still needs its actual reachable coordinator.

Separately, `rdma.cpp:184–220` queries the selected device's port1 GID table and selects the first entry whose first ten bytes are zero and next two are ff ff: an IPv4-mapped GID. It throws if none is found, with an explicit interface-IPv4 diagnostic. `create_connections`, 282–324, selects the configured RDMA device by exact name. `mesh.cpp:58–62` calls Connection.info for its entries before the first destination all-gather. Therefore a missing mapped GID can fail before the owner receives any native bootstrap round, even with a correctly authenticated channel.

`queue_pair_rtr`, rdma.cpp:241–258, still installs the peer's exchanged GID and uses a fixed source GID index1. The query loop chooses the first matching entry but does not propagate its actual index into that assignment; this existing behavior is unchanged. The callback does not replace RDMA device discovery, its GID table, addressing, or payload transport, and does not encrypt RDMA traffic.

The exact temporary address 169.254.70.47 is not required by this source. Some usable IPv4-mapped GID on the actual selected device remains required. If the existing temporary alias supplies the only such GID, replacing the TCP bootstrap with the callback is not evidence that the alias can be removed. Whether peer48 has another suitable mapped GID is a live-state question left to root's read-only device checks; this note supplies no such observation. `experiments/cluster/transport/README.md:35–40` independently documents that an IPv6-only link is insufficient for this pinned JACCL revision.

## Exact current facade relay schedule

The current product facade admits **only a two-rank mesh**. It rejects both ring environment names and requires a 2×2 matrix, null diagonal, and exactly one string device per off-diagonal (`QwenResidentJACCLConfiguration.swift:79–81,115–128`). There is no need to admit ring in the initial authenticated relay.

`Config::get_mesh_connectivity`, jaccl.cpp:183–192, returns a vector with world-size entries including the empty self slot. `create_connections` preserves that slot with a null context. `mesh.cpp:58–62` includes an info entry for every connection. Consequently each rank's native vector has **two** Destination elements, not one.

| Sequence | Contribution from each rank | Concatenated reply |
| --- | --- | --- |
| 0 | Native C++ int equal to2 | Two exact count values in rank order |
| 1 | `2 * sizeof(jaccl::Destination)` opaque bytes | Twice that byte length, rank0 then rank1 |
| 2 | Native C++ int zero | Two exact zero values |
| 3 | Native C++ int zero | Two exact zero values |

`rdma.h:307–344` first gathers each vector's native int length, takes its maximum, allocates a native buffer, and only then invokes the data callback. `rdma.h:351–354` makes both scalar barriers. A current arm64 Darwin native int is four bytes and little endian, so sequences0/2/3 must be exactly `02 00 00 00` / `00 00 00 00` / `00 00 00 00`, with eight-byte gathered replies. Reject mismatched, negative, zero/huge counts and unexpected rounds before replying to sequence0; accepting a bounded raw frame without checking that scalar would leave the native allocation vulnerability described in the shim handoff.

The current SDK `infiniband/verbs.h:81–87` defines ibv_gid as a 16-byte union including two uint64 fields. `rdma.h:91–96` defines Destination as three int fields followed by that union. Under the supported arm64 Darwin ABI this yields 32-byte Destination storage (12 bytes of ints, alignment padding, 16-byte GID), hence 64 bytes per rank and a 128-byte gathered reply for sequence1. This size is **source/ABI-derived here**, not measured by compiling or executing a native helper in this review. Before physical relay qualification, bind a root-owned lightweight static assertion of `sizeof(int)==4`, `sizeof(jaccl::Destination)==32`, and little-endian native target to the exact build. The relay can then use those admitted sizes without defining or decoding a Swift RDMA structure. Native payload contents and padding stay opaque; do not impose invented zero-value rules on the unused self slot.

The relay must bind its expected schedule to the actual selected matrix/topology and configured worker/build/owner identities. It must obtain one contribution per rank for the same epoch/sequence, enforce equal admitted lengths, return exact rank-ordered concatenation and preserve the sender's local bytes. Completion of four rounds is bootstrap completion only; loaded agreement, source/Plan checks, actual native cleanup and peer retirement remain separate. Socket EOF, a sent reply, or a callback return is not peer-consumption or process-fence proof.

Generic native ring support remains in the source but is outside this initial facade: ring.cpp:67–76 sends left and right vectors separately before the two barriers. Supporting it later would require the selected connection-count contract and six distinct rounds; accepting any four/six arbitrary byte messages is not sufficient.
