package analyticssql

// analyticsWorkMem is the per-transaction work_mem for the analytics
// statements behind /v1/stats and /v1/network/totals. Each sorts or hashes
// every located usage row of the last 24 h (COUNT(DISTINCT) / GROUP BY over
// ~3 M rows in production); at the instance default of 4 MB that is an
// external merge sort spilling >1 GB of temp files per execution. SET LOCAL
// scopes the raise to the one read-only transaction, so the instance setting
// stays untouched. The budget is per sort/hash node; hash_mem_multiplier is
// pinned to 1.0 in the same transaction so a hash aggregate cannot take
// twice this (the PG 15+ default multiplier is 2.0). Only the cache
// refreshers run these statements — one stats pipeline and one totals
// window at a time — so the transient memory is bounded to a few GB.
const WorkMem = "1GB"
