package store

// DefaultPruneMaxEntries is the default per-slice cap used by Prune.
// At ~1 KB per entry this keeps each slice around ~100 MB, well under the
// coordinator's typical memory budget on a t3.small.
const DefaultPruneMaxEntries = 100_000
