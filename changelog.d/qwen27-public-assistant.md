### Qwen3.8-27B pairs can keep their speculative assistant on public traffic once declared

- A build can now declare Qwen3.8-27B's resident speculative assistant public
  for its tensor-parallel pairs, the way the public model declaration names a
  model's mode families: the exact depth, head inventory and singleton
  verification, with the SHA-256 of its evidence report. This build declares
  none, so coordinator-paired setups still carry no assistant and nothing
  changes until the owner signs a declaration after the real-pair evidence.
- With a declaration, the guided setup plans a cluster served through
  Darkbloom with the declared assistant under `mtp_mode = "auto"`, each Mac
  admits a cluster approval beside exactly that assistant (any other is
  refused before any part stops), and the release's cluster runtime facts, the
  coordinator's approval and every committed start name it in their resource
  policy digest. Without a declaration that digest is unchanged.
- A pair whose ranks report the resident assistant ready now shows MTP as
  configured in its slot posture and heartbeats, with the counts its runtime
  reports, instead of disabled.
- The refusal of an undeclared assistant beside an approval now says it serves
  local clusters only unless the build declares it public.
