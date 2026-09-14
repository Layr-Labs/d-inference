// Package dispatchplan owns request-local alternate selection and the capacity
// probes that confirm or demote those same entries.
//
// Plan keeps the bounded shortlist, consumed cursor, attempted provider IDs,
// quote ranking and single-refresh claim behind one private mutex. Builder
// initializes it at its final address before publication. Connection is an
// opaque comparable value: the registry binds *Provider and checks that exact
// pointer against the current registry before reserving. No plan operation
// dereferences a connection or reserves provider capacity.
//
// Probes owns reply correlation, expiry and collector settlement. Its private
// mutex is a leaf: only buffered, exactly-once deliveries happen under it.
// Readiness, data-lane writes and logger bindings run outside owner locks. A
// collector updates the plan before publishing an outcome. The registry calls
// FailProvider at its existing disconnect cleanup point after releasing the
// registry and provider locks; live heartbeat sequence state stays there too.
//
// The root reservation adapter retains registry-to-provider lock ordering,
// live admission/deadline checks and pending-request debit. Refresh claims and
// next-entry consumption release the plan lock before invoking any live scan
// or provider work. The owner never calls back into those transactions.
package dispatchplan
