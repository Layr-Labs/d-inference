### Page cache no longer blocks model loads

- Count the file-backed page cache and volatile purgeable pages as available memory in load admission, KV budgets, cold-load capacity, `darkbloom status` and `darkbloom doctor`. Clean cached files left by `darkbloom models download` or weight hashing are dropped by macOS without compressing or swapping any process memory; they previously counted as used whenever they were active, so a 256 GB Mac reported 170.8 GB usable with about 250 GB of page cache and refused GLM-5.3-Flash's 185.4 GB cold load until `sudo purge`.
- Anonymous memory, including inactive anonymous pages, and compressed memory no longer count as available. `DARKBLOOM_MEMORY_AVAILABILITY=free-only` still counts free pages only.
