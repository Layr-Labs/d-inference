### `cluster status` says why a load keeps starting again

- While a Mac's part of the pair keeps ending and starting again during a load, `darkbloom cluster status` and `cluster status --json` now give that end as the reason, as the start's screen says it, for example "this Mac's part ended (exit 1: deadline) and starts again by itself". Before, both Macs said only `loading`, with no reason.
