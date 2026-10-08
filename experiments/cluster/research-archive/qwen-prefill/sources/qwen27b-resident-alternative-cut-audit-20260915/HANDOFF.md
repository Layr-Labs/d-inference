# Initial 27B load requirements by cut

Metadata-only arithmetic using the exact a7c35 source and 1847 retained constructor leaves. No alternative Plan/profile fingerprint is invented, and no model was loaded.

| Cut | Rank 0 required free | Rank 1 required free | Existing native | Existing owner |
| --- | ---: | ---: | --- | --- |
| 16 | 9,727,600,687 B (9.060 GiB) | 16,602,658,967 B (15.462 GiB) | accepted | refused |
| 24 | 11,446,365,257 B (10.660 GiB) | 14,883,894,397 B (13.862 GiB) | refused | refused |
| 32 | 13,165,129,827 B (12.261 GiB) | 13,165,129,827 B (12.261 GiB) | accepted | accepted |
| 40 | 14,883,894,397 B (13.862 GiB) | 11,446,365,257 B (10.660 GiB) | refused | refused |

The current supported native cuts are 4/8/12/16/32. Cut16 leaves the native/profile scope unchanged but needs a separately pinned private owner/configuration and prospective agreement. Cuts24/40 preserve the four-layer constructor phase but need a changed native allowlist, which also changes the registered planning-scope fingerprint.

Each requirement is max(6 GiB, remaining per-leaf allocator upper bounds + twice the largest host tensor + 8 MiB/16 KiB scratch + 4 GiB). Both ranks retain largest host tensor635,699,200 B; inert leaves are counted separately. The allocator test adds actual active/cache memory to the report’s initialAllocatorAdditionalBytes. These are initial gates, not guarantees for later load/request gates.

The full per-leaf ledger and source pins are retained beside this note. Cut32 exactly reproduces both original stage-local inventories and the initial13,165,129,827-byte requirement.
