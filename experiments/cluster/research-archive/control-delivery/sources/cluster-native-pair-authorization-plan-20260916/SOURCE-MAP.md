# Existing code that the proposal changes or reuses

- coordinator/registry/verified_pair_reservation.go: Reserve, Acknowledge,
  Commit (before any child), Validate; exact Provider identity and active-state
  transition. verified_pair_lifecycle.go owns quarantine/actual release.
- coordinator/registry/verified_pair_types.go explicitly says proposed native
  binding is not approval. No approved-native authority exists there today.
- coordinator/api/provider.go handles actual registered connection; new grant
  handlers belong on that connection after current trust/freshness checks.
- ProviderCore/Security/AttestationSigner.swift is the existing SE signing
  abstraction. coordinator/attestation/attestation.go parses current bound
  P-256 key/signatures; no native traffic private key belongs in that layer.
- CoordinatorClient+Connection.swift currently permits ws for fixtures and wss
  for production. Protected grant establishment must require authenticated TLS;
  member-role ACK alone must not turn an insecure transport into authority.
- DistributedInstalledSession.swift currently owns concrete endpoints and
  constructs localOwner for its rank / SSH for its peer. This is the narrow
  endpoint/lifetime seam to generalize, not a replacement request engine.
- ClusterRemoteWorkerEndpoint.swift localOwner constructor already launches
  the fixed owner and retains bounded worker events, actual native cleanup,
  authenticated lease release and owner transport completion.
- ClusterWorkerOwnerService.swift records the journal before native launch;
  its child factory must return an unlaunched process. Prelude failure still
  uses its actual child cleanup and retained-journal/release protocol.
- ClusterOwnerBootstrapAttachment.swift obtains child.launchedProcessIdentifier
  and accepts exactly that peer on its own bootstrap listener. Its current
  completion is four mesh rounds, not approval or native retirement.
- ClusterBootstrapConnection/Listener authenticate same-Mac PID and private
  directory/socket; connection has bounded IO, one operation and invalidation.
  Current gather reply equality/echo precludes silently stuffing grant bytes.
- QwenResidentRuntime+Load.swift currently constructs Collective before load
  intent/weights; protected native authorization must precede that constructor.
- ClusterAuthenticatedRecordChannel/State/Types own directional keys, exact
  scope/AAD, sequence exhaustion, byte budgets and invalidation. They receive a
  key but do not assert membership, native approval or resource admission.

All 22 MAIN source pins are in source-pins.json. The proposed member role base
is frozen manifest4ae431c6; protected facade4338ce5b is a separate private input.
No MAIN/source implementation changes, compiler, model, remote, credential read
or deployment was performed for this proposal.
