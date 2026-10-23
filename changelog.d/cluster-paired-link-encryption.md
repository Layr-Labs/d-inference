### Require encrypted native traffic for paired-link text clusters

Installed paired-link text sessions now require matching workers with keyed
data-plane support on both Macs. Each rank receives its own session credential,
and startup refuses plaintext, unverified or mismatched readiness before serving.
Existing private-image and GLM encryption requirements remain unchanged.
