# Exact next delta after this invocation qualification

This patch ends at native confirmation and clean retirement. The following
bounded changes are required to reach real encrypted development inference.
They are not implemented or enabled by this source package.

1. **Configured CLI and real installed owner.** Add an explicit versioned native
   member attachment to the existing installed cluster configuration. Bind its
   selected owner/native/metallib/resource/capability/profile/Plan to the same
   validated installation and coordinator-approved policy. At
   `Start.makeClusterMemberLoop` (`StartCommand+ClusterMember.swift`), construct
   that installation after `ClusterMemberPreparation` and invoke
   `loop.installNativePairMember` before returning the loop. Both follower and
   retained leader already use this constructor; no parallel provider engine is
   needed. Preserve the ordinary omitted attachment and ordinary model hardware
   gate. Extend `DistributedInstalledOwner.run` only for a separately qualified
   protected-native profile; the current `.mesh2` path stays unchanged. That
   owner validates the configured policy before the shared service callback, and
   its actual native factory consumes the public start argument. The key-only
   CPU helper is not this installed owner and grants no runtime approval.

2. **Four existing mesh rounds through the same B session.** The current ABI is
   closed: native contributions are 4-byte int32 count two, 64 destination bytes,
   then two 4-byte zero barriers. Gathered replies are respectively 8, 128, 8, 8
   bytes. Add mirrored, domain-bound `native_pair_mesh` / reply public records
   and an explicit transcript-digest key-confirmed record to B's existing
   protocol/handler/relay. Keep the 64 KiB WebSocket and 32 KiB payload ceilings;
   these exact rounds fit without chunking. Validate rank, active committed grant,
   native transcript and round 0…3 before enqueue, using the same connection
   sequences, bounded writers, cancel-publication barrier and original deadlines.
   Both native key-confirmed records must precede admitting mesh round zero.
   Gather rank 0 then rank 1 using the current profile rules, not a second mesh
   engine. Reject duplicate, skipped, early or wrong-sized rounds.

   Add a separate combined owner profile. Its three key public exchanges remain
   first; map native socket mesh sequences 0…3 to owner public sequences 3…6.
   Broaden OwnerWire's round bound only for this closed combined profile, never
   globally. Replace the key-only local completion marker with the existing four
   socket rounds. A already transitions the *same* authenticated connection to
   mesh mode after bilateral confirmation. The owner must retain the attachment
   until all four replies are consumed; no native Ready before that barrier.

3. **Protected group before loading.** The native entry parses the exact start,
   claims A's owned prelude and retains `ClusterNativeRecordAuthority`. After
   confirmation, pass the existing connection to `QwenResidentBootstrap.make` →
   `JACCLBootstrap.initialize`, preserving its once-only callback and full
   existing source lifetime. Once the group exists, construct the authority's
   record transport once with the private ciphertext byte IO. Feed it into the
   already drafted `CollectiveProtectedSession` / immutable `CollectiveRecordScope`
   facade before `QwenResidentRuntime.load` or any intent/loaded/request readiness
   exchange. Do not call the ordinary plaintext load constructor. Native keys
   stay in the authority; only public transcript/start bytes cross owner NDJSON.
   All three readiness exchanges, residuals, control lengths/tokens/decisions,
   ACKs and retirement use protected scopes. Protected raw reduction/barrier APIs
   remain refused. Exact-size hot records use one plaintext-size-plus-40 frame
   and one completed send/receive, not a second prefix fence.

4. **Admit actual sealed memory and lifetime before Ready.** The protected facade
   deliberately has a closed resource gate. Bind the actual two-Mac native
   allocation qualification and initialized-tail backend fix to the selected
   native binary, concrete buffer geometry, peak live allocation and resource
   policy. Charge ciphertext/Data staging, any padding and record budget before
   admission; reserve the known worst-case transfer envelope against cumulative
   per-direction limits. A's 16 MiB software ceiling is not RDMA permission.
   Keep native state/request owner, preparation/lifetime, request TTFT and cleanup
   paths shared; start no fresh SLA at key confirmation or native Ready.

5. **Qualify exact working 9B development path first.** Require real TLS/member
   identity, explicit non-default coordinator native approval, both actual owned
   native PIDs, key-confirmed transcript, four actual mesh rounds, protected load
   readiness, one fixed developer prompt, exact greedy output against the pinned
   reference, tamper/replay refusal and bilateral natural cleanup/lease release.
   An ordinary registry model entry is not native approval. The current 27B
   M5/NAX restriction must remain until a separately explicit approved adapter
   policy establishes its supported non-NAX arithmetic/runtime/hardware path.
   No renamed model, fake kernel capability, SSH/plaintext fallback, second state
   owner or bypass of serving-resource admission is acceptable.

Relevant source pins are retained in `context-pins.json`; the protected facade
remains a separate source-only dependency in
`collective-protected-scopes-draft-20260915` (manifest `4338ce5b…fee107`).
