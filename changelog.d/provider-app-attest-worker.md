### Supervised App Attest worker candidate

- Add a default-off, same-signed-executable App Attest worker candidate. Keep the inference key in the parent process, bind proof replies to their originating socket, and retire the owned worker before replacement without restarting inference.
- Fence update installation and restart on confirmed worker retirement and current lifecycle ownership. After a failed update, fresh verification can retry cleanup of the retained owner; terminal shutdown cannot reopen it.
- Record artifact-bound native suspended-worker and assertion-callback recovery passes. Loaded-engine continuity and composed two-minute resumption remain pending; these component results do not qualify later rebuilt artifacts or establish production readiness.
