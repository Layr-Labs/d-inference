# Source closure and review map

- Wire: protocol/execution_role.go and messages.go mirror Swift
  Protocol/ProviderExecutionRole.swift, Messages.swift, ProtocolCodec.swift.
  Raw-attestation encoding has the same new optional fields as Codable.
- Registration: api/provider.go validates and ACKs before existing attestation;
  registry/provider_lifecycle.go stores the private immutable role and joins
  cluster_models into its ordinary model view only on recognized member role.
- Reader paths: routing_eligibility.go feeds scheduler selection/admission,
  private self-route, model capacity, aliases and normal load readers.
  warm_pool_controller.go has its own reasoned gate; model_loading.go rechecks
  at pending-load commit; verified_pair_commands.go checks before socket IO.
  Existing empty desired revoke remains safe. No pending-load arithmetic changed.
- Pair exception: scheduler -> liveness takes an explicit private pair-only
  eligibility context. verified_pair_membership.go is its only true caller;
  nil prior hold at initial reservation cannot accidentally mean solo.
- Connection failure: CoordinatorClient+Connection.swift resets negotiation
  per connection, bounds ACK wait and retains existing receive/ping/failure
  loop. +Inbound checks the local expected nonce before publication.
  No request content is placed in a log or new acknowledgment.
- Model ownership: ProviderLoop+Serve.swift conditionally skips all solo
  startup/maintenance entry points. +ClusterMember owns small role-specific
  event/wait state; +ModelLoading/+Preload/+Prefetch/+InferenceHandler also
  guard direct callers. No decoder, scheduler or native owner is duplicated.
- CLI: StartCommand dispatches member/distributed before solo device exclusion
  and requireMetal. +ClusterMember shares construction for follower/leader.
  +Distributed keeps the member task, a terminal observer and existing host;
  every normal/error return cancels and joins control before returning.
- Startup verification: ClusterMemberPreparation calls existing read-only
  InstalledValidation, canonical exclusion and WeightHasher. BinaryHasher's
  binder -> ProviderMetallibControl.cpp -> metal.cpp:set_metallib_path only
  sets g_metallib_path; no inference or GPU dispatch. Metadata and full-hash
  duration boundaries are distinct as recorded in HANDOFF.

Reviewed V2 base: coordinator-verified-pair-draft-v2-20260915 manifest 22022f17;
now exact MAIN. Its independent review and actual race receipts are separate.
This new overlay's independent final review and all execution remain pending.
No application secrets, weights, machine-specific fixture paths or binaries are
added to repository sources. Test wrappers select the existing local toolchain
explicitly and never download tools/dependencies or contact a remote service.
