// Package faultstate owns reconnect-resistant routing fault state.
//
// Manager owns the session/identity index, disconnected identity redirects,
// construction-time policy and sweep anchor. Each private gate owns the seven
// coupled trackers: dispatch-load and inference-error cooldowns, the node-health
// breaker, health ejection, capacity cooldown, capacity-rate history and budget
// clamps. Version-reset history shares the same gate transaction.
//
// Registry binds one Session to each exact Provider pointer. It retains its
// registry and provider mutexes, attested identity derivation, current budget
// reads, health-ejection switch and routing verdict order. Connections are opaque
// here; a retired session cannot rebind or reset its replacement's history.
//
// Lock order is registry -> provider -> index -> gate. Recorders normally resolve
// under the index read lock, release it, then validate the binding under the gate
// lock. A stale binding releases the gate before resolving again. Retry exhaustion
// takes the index write lock before the gate. Migration alone holds two gates,
// always under the index write lock; no callback takes a registry/provider lock.
//
// Migration publishes destination state, repoints the session, redirects cached
// disconnect identities, then forwards or resets the source in that order. An
// orphan retains conservative atomics and forwards before reset; a shared source
// is republished only after the moving session points at its destination. Sweep
// marks retirement under the gate lock before deleting the index entry.
//
// Views retain a private binding and confirm each dispatch-deciding read batch
// with Moved. CapacityAccept retains its reference across the caller's optional
// budget snapshot, then validates under the gate lock. CapacityProbe performs the
// same validated check-and-claim and skips the observer while caller locks are
// held. Other wait observations run after gate release. Status values copy their
// histories; callers cannot mutate gates, indexes or mutexes through this API.
package faultstate
