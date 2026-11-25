# Resource policy supersession

2026-09-14. The initial, unqualified `PLAN.md` is preserved at SHA256
`a9ce65081be6acdfddcd9b0250f0e958be58fee7f84a01400c9580228224ae36`.
Its proposed reclaimable-byte threshold and `2 * largestHost + 1 GiB` actual-free
threshold were rejected during root review and are not the implemented policy.
The plan's reference to a future `source-pins.json` did not become a frozen source
inventory; the implementation package below contains the actual inventories.

The reviewed implementation is frozen in
`../registered-dense-stage-load-draft/manifest.json` at SHA256
`a9b31d48785226b75ba684a96c4e916d229bfe7bcc4b25f2c88d33150e9db244`.
Its current implementation contract is `../registered-dense-stage-load-draft/HANDOFF.md`.
At each selected-load observation, actual free bytes must be at least
`max(6 GiB, remaining allocation bound + 2 * remaining largest host + 4 GiB)`.
The allocator limit must accommodate current active/cache plus remaining
allocation, one remaining largest-host tensor and 2 GiB. Reclaimable bytes and
the recommended working set are diagnostic only; no caller reserve, metadata
object, or advisory byte estimate authorizes loading. Pressure remains at most
2 and absolute reported swap must be zero. The independent initial and final
actual-free screens retain the 6 GiB minimum.

These fixed headroom rules are operational screens, not memory reservations or
measured whole-process peak bounds. The frozen package has only source checks
and prospective pure predicate fixtures at handoff; root owns compilation and
native qualification. Its fixtures do not execute the private live gate or a
partial materialization/cleanup path.
