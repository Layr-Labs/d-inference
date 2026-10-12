### Supervised App Attest worker candidate

- Add a default-off, same-signed-executable App Attest worker candidate. Keep the inference key in the parent process, bind proof replies to their originating socket, and retire the owned worker before replacement without restarting inference.
- Fence update installation and restart on confirmed worker retirement and current lifecycle ownership. After a failed update, fresh verification can retry cleanup of the retained owner; terminal shutdown cannot reopen it.
- Preserve the exact worker opt-in in background `darkbloom start`; keep native diagnostic/fault flags out of the daemon. Reject the unused component-only transport-resumption scenario rather than reporting unproven success.
- Record artifact-bound native suspended-worker, loaded-engine assertion-callback recovery, and separate composed two-minute resumption passes. These results do not qualify later rebuilt artifacts or the full OS/security-transition and fleet-rollout matrix.
