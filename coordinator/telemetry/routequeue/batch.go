package routequeue

// Worker-side grouping for Sink: gather a bounded run of queued ops,
// then persist it with as few store calls as its contents allow.
//
// INVARIANT: exactly one worker consumes the queue (NewBatching
// clamps workers to 1). Everything below assumes a single FIFO consumer.
//
// Ordering guarantee. The only order the store depends on is PER ROUTE KEY
// (request_id, attempt): a row's insert must be written before any outcome
// update for it (an UPDATE on a missing row is a silent no-op on both
// backends), later updates must land after earlier ones, and a re-record of
// the same key (dispatch.go records "queued", then "selected") must land after
// the first insert and after any update that preceded it in the queue.
//
// Submission order already satisfies all of that: dispatch records the route
// before the provider can produce a commit or terminal, and the single worker
// consumes the queue FIFO. execute keeps it while coalescing by
//
//   - writing every record of a group FIRST (one multi-row upsert), then
//     walking the rest of the group in queue order — updates coalesced into
//     pipelined runs, generic closures inline;
//   - refusing to add a record to a group whose key already has an insert OR
//     an update in that group (group.conflicts): such a record starts
//     the next group, so moving inserts to the front of a group can never move
//     one across a same-key op. Distinct keys are independent rows, so their
//     relative order is free.
//
// Groups execute sequentially on the one worker, so cross-group order is FIFO.
//
// Failure policy. A batch call runs under its own recover; a panic or error
// is a failed batch. When the failure is a ROW fault (constraint, type, ...)
// and the sink is still open, every row is replayed on its own — each under
// its own recover — so one poison row cannot discard its neighbours and every
// failure keeps the per-row diagnostic the single-write path always logged.
// When the store is UNAVAILABLE (deadline, connection, closed pool, server
// shutdown) or the sink is closing (the pool is about to go away), the group
// is dropped and counted instead: N sequential replays would only be N more
// timeouts and N error lines.

import (
	"fmt"
	"strconv"

	"github.com/eigeninference/d-inference/coordinator/saferun"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// group is one gathered run of ops, executed together.
type group struct {
	ops        []operation
	records    []*store.InferenceRouteRecord
	insertKeys map[string]struct{}
	updateKeys map[string]struct{}
}

func newGroup(capacity int) *group {
	return &group{
		ops:        make([]operation, 0, capacity),
		insertKeys: map[string]struct{}{},
		updateKeys: map[string]struct{}{},
	}
}

func routeTelemetryKey(requestID string, attempt int) string {
	return requestID + "/" + strconv.Itoa(attempt)
}

// conflicts reports whether op must NOT join this group: it is a route record
// whose key already has an insert (a single multi-row upsert cannot touch one
// row twice, and the later record must land after the earlier one) or an
// update (which must stay before this re-record) in the group.
func (g *group) conflicts(op operation) bool {
	if op.record == nil {
		return false
	}
	key := routeTelemetryKey(op.record.RequestID, op.record.Attempt)
	if _, dup := g.insertKeys[key]; dup {
		return true
	}
	_, afterUpdate := g.updateKeys[key]
	return afterUpdate
}

func (g *group) add(op operation) {
	g.ops = append(g.ops, op)
	switch {
	case op.record != nil:
		g.records = append(g.records, op.record)
		g.insertKeys[routeTelemetryKey(op.record.RequestID, op.record.Attempt)] = struct{}{}
	case op.update != nil:
		g.updateKeys[routeTelemetryKey(op.update.RequestID, op.update.Attempt)] = struct{}{}
	}
}

// execute persists one group: all records first (one store call), then the
// remaining ops in queue order with runs of updates pipelined (one store call
// per run) and generic closures inline. Every store call and closure runs in
// its own panic-safe unit so one failure cannot skip the rest of the group.
func (t *Sink) execute(g *group) {
	if len(g.records) > 0 {
		records := g.records
		t.runUnit(func() { t.persistRoutes(records) })
	}
	var pending []operation
	flush := func() {
		if len(pending) == 0 {
			return
		}
		batch := pending
		pending = nil
		t.runUnit(func() { t.persistOutcomes(batch) })
	}
	for _, op := range g.ops {
		switch {
		case op.update != nil:
			pending = append(pending, op)
		case op.fn != nil:
			flush()
			t.runUnit(op.fn)
		}
	}
	flush()
}

// runUnit executes fn with saferun's recover semantics (log + observe a panic,
// never propagate it). It reuses saferun.Recover rather than saferun.Go
// precisely so no new goroutine is spawned per unit.
func (t *Sink) runUnit(fn func()) {
	defer saferun.Recover(t.logger, "telemetrySink")
	fn()
}

// tryBatch runs one batch store call and reports a panic as an error, so the
// caller handles it as a failed batch (replay or drop) instead of losing the
// rest of the group. The panic is re-raised inside saferun.Recover while the
// panicking frames are still on this stack, so it is logged and observed
// exactly like any other telemetry unit.
func (t *Sink) tryBatch(name string, fn func() error) (err error) {
	defer func() {
		r := recover()
		if r == nil {
			return
		}
		func() {
			defer saferun.Recover(t.logger, "telemetrySink."+name)
			panic(r)
		}()
		err = fmt.Errorf("telemetry batch %s panicked: %v", name, r)
	}()
	return fn()
}

// rowFault reports whether a failed write should be handled per row: the
// sink is still open and the error describes the rows rather than the
// store's availability. Otherwise the caller drops and counts.
func (t *Sink) rowFault(err error) bool {
	return !t.isClosed() && !store.IsTransientWriteError(err)
}

// dropGroup counts rows that will not be persisted and says why, once.
func (t *Sink) dropGroup(kind string, rows int, err error) {
	t.countDrops(rows)
	if t.logger != nil {
		t.logger.Warn("routing telemetry group dropped",
			"kind", kind,
			"rows", rows,
			"closing", t.isClosed(),
			"error", err,
		)
	}
}

// persistRoutes writes a group's records with one multi-row call, then applies
// the failure policy from the file header.
func (t *Sink) persistRoutes(records []*store.InferenceRouteRecord) {
	st := t.store
	if st == nil {
		return
	}
	writeOne := func(r *store.InferenceRouteRecord) {
		t.runUnit(func() {
			err := st.RecordInferenceRoute(r)
			switch {
			case err == nil:
			case t.rowFault(err):
				LogRecordWriteError(t.logger, r, err)
			default:
				t.dropGroup("inference_routes", 1, err)
			}
		})
	}
	if len(records) == 1 {
		writeOne(records[0])
		return
	}
	err := t.tryBatch("recordInferenceRoutes", func() error { return st.RecordInferenceRoutes(records) })
	if err == nil {
		return
	}
	if !t.rowFault(err) {
		t.dropGroup("inference_routes", len(records), err)
		return
	}
	if t.logger != nil {
		t.logger.Warn("inference_routes batch write failed — retrying rows individually",
			"rows", len(records),
			"error", err,
		)
	}
	for _, r := range records {
		writeOne(r)
	}
}

// persistOutcomes applies a run of outcome updates with one pipelined call,
// then applies the failure policy from the file header. Outcome merges are
// idempotent ("set when non-zero"), so a replay after a rolled-back pipeline
// is safe.
func (t *Sink) persistOutcomes(ops []operation) {
	st := t.store
	if st == nil {
		return
	}
	writeOne := func(op operation) {
		t.runUnit(func() {
			u := op.update
			err := st.UpdateInferenceRouteOutcome(u.RequestID, u.Attempt, u.Outcome)
			switch {
			case err == nil:
			case t.rowFault(err):
				LogOutcomeWriteError(t.logger, u.RequestID, u.Attempt, op.model, u.Outcome, err)
			default:
				t.dropGroup("inference_routes_outcome", 1, err)
			}
		})
	}
	if len(ops) == 1 {
		writeOne(ops[0])
		return
	}
	updates := make([]store.InferenceRouteOutcomeUpdate, 0, len(ops))
	for _, op := range ops {
		updates = append(updates, *op.update)
	}
	err := t.tryBatch("updateInferenceRouteOutcomes", func() error { return st.UpdateInferenceRouteOutcomes(updates) })
	if err == nil {
		return
	}
	if !t.rowFault(err) {
		t.dropGroup("inference_routes_outcome", len(ops), err)
		return
	}
	if t.logger != nil {
		t.logger.Warn("inference_routes outcome batch update failed — retrying rows individually",
			"rows", len(ops),
			"error", err,
		)
	}
	for _, op := range ops {
		writeOne(op)
	}
}
