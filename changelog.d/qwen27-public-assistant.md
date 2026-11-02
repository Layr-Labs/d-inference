### Qwen3.8-27B pairs can keep their speculative assistant on public traffic once a build declares it

- Nothing changes in serving until a build declares the assistant public. This
  build declares none: coordinator-paired Qwen3.8-27B setups still carry no
  speculative assistant, and every release fact, approval and committed start
  keeps its resource policy digest. The owner declares one only after the
  real-pair evidence.
- A declaration names the exact depth, head inventory and singleton
  verification, with the SHA-256 of its evidence report, beside the public
  model declaration. Once a build carries one:
  - the guided setup plans a cluster served through Darkbloom with that
    assistant under `mtp_mode = "auto"`;
  - each Mac admits a cluster approval beside exactly that assistant, and any
    other is refused before any part stops;
  - the release's cluster runtime facts, the coordinator's approval and every
    committed start name it in their resource policy digest;
  - the pair's slot posture shows MTP as configured, with the counts its
    runtime reports.
- The only change visible now is the wording of one refusal: an assistant
  beside a cluster approval is refused as serving local clusters only "unless
  this build declares it public".
