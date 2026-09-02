package api

// Worker-side grouping for telemetrySink: gather a bounded run of queued ops,
// then persist it with as few store calls as its contents allow.
//
// INVARIANT: exactly one worker consumes the queue (newBatchingTelemetrySink
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
//     an update in that group (telemetryGroup.conflicts): such a record starts
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
	"time"

	"github.com/eigeninference/d-inference/coordinator/saferun"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// telemetryGroup is one gathered run of ops, executed together.
type telemetryGroup struct {
	ops        []telemetryOp
	records    []*store.InferenceRouteRecord
	insertKeys map[string]struct{}
	updateKeys map[string]struct{}
}

func newTelemetryGroup(capacity int) *telemetryGroup {
	return &telemetryGroup{
		ops:        make([]telemetryOp, 0, capacity),
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
func (g *telemetryGroup) conflicts(op telemetryOp) bool {
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

func (g *telemetryGroup) add(op telemetryOp) {
	g.ops = append(g.ops, op)
	switch {
	case op.record != nil:
		g.records = append(g.records, op.record)
		g.insertKeys[routeTelemetryKey(op.record.RequestID, op.record.Attempt)] = struct{}{}
	case op.update != nil:
		g.updateKeys[routeTelemetryKey(op.update.RequestID, op.update.Attempt)] = struct{}{}
	}
}

// worker drains the queue until the sink is closed. The worker IS the
// long-lived goroutine — it runs each group inline (inside panic-safe
// wrappers) and never spawns a goroutine per op. carry holds an op that
// conflicted with the previous group and therefore opens the next one.
func (t *telemetrySink) worker() {
	defer t.workers.Done()
	var carry *telemetryOp
	for {
		var first telemetryOp
		if carry != nil {
			first = *carry
		} else {
			select {
			case first = <-t.ch:
			case <-t.done:
				t.drainOnClose(nil)
				return
			}
		}
		g, next := t.gather(first, t.liveNext())
		t.execute(g)
		carry = next
		select {
		case <-t.done:
			t.drainOnClose(carry)
			return
		default:
		}
	}
}

// liveNext returns the op source for a live group: it blocks for the next op
// until the group window elapses or the sink is closed.
func (t *telemetrySink) liveNext() func() (telemetryOp, bool) {
	var timer *time.Timer
	return func() (telemetryOp, bool) {
		if timer == nil {
			timer = time.NewTimer(t.window)
		}
		select {
		case op := <-t.ch:
			return op, true
		case <-timer.C:
			return telemetryOp{}, false
		case <-t.done:
			timer.Stop()
			return telemetryOp{}, false
		}
	}
}

// bufferedNext returns the op source for a closing drain: whatever is already
// buffered, without waiting.
func (t *telemetrySink) bufferedNext() func() (telemetryOp, bool) {
	return func() (telemetryOp, bool) {
		select {
		case op := <-t.ch:
			return op, true
		default:
			return telemetryOp{}, false
		}
	}
}

// gather builds a group starting with first, pulling from next until the
// group is full, next runs dry, or an op conflicts with the group — in which
// case that op is returned as the carry for the following group.
func (t *telemetrySink) gather(first telemetryOp, next func() (telemetryOp, bool)) (*telemetryGroup, *telemetryOp) {
	g := newTelemetryGroup(t.maxBatch)
	g.add(first)
	for len(g.ops) < t.maxBatch {
		op, ok := next()
		if !ok {
			return g, nil
		}
		if g.conflicts(op) {
			return g, &op
		}
		g.add(op)
	}
	return g, nil
}

// drainOnClose writes everything buffered at close time, in groups, without
// waiting for more. It runs on the worker goroutine after done is closed, so
// close itself never blocks on it; closeAndWait bounds how long a caller
// waits for it. Because close rejects new submits, the buffer only shrinks.
func (t *telemetrySink) drainOnClose(carry *telemetryOp) {
	next := t.bufferedNext()
	for {
		var first telemetryOp
		if carry != nil {
			first = *carry
		} else {
			op, ok := next()
			if !ok {
				return
			}
			first = op
		}
		g, more := t.gather(first, next)
		t.execute(g)
		carry = more
	}
}

// execute persists one group: all records first (one store call), then the
// remaining ops in queue order with runs of updates pipelined (one store call
// per run) and generic closures inline. Every store call and closure runs in
// its own panic-safe unit so one failure cannot skip the rest of the group.
func (t *telemetrySink) execute(g *telemetryGroup) {
	if len(g.records) > 0 {
		records := g.records
		t.runUnit(func() { t.persistRoutes(records) })
	}
	var pending []telemetryOp
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
func (t *telemetrySink) runUnit(fn func()) {
	defer saferun.Recover(t.logger, "telemetrySink")
	fn()
}

// tryBatch runs one batch store call and reports a panic as an error, so the
// caller handles it as a failed batch (replay or drop) instead of losing the
// rest of the group. The panic is re-raised inside saferun.Recover while the
// panicking frames are still on this stack, so it is logged and observed
// exactly like any other telemetry unit.
func (t *telemetrySink) tryBatch(name string, fn func() error) (err error) {
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
func (t *telemetrySink) rowFault(err error) bool {
	return !t.isClosed() && !store.IsTransientWriteError(err)
}

// dropGroup counts rows that will not be persisted and says why, once.
func (t *telemetrySink) dropGroup(kind string, rows int, err error) {
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
func (t *telemetrySink) persistRoutes(records []*store.InferenceRouteRecord) {
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
				logRouteRecordWriteError(t.logger, r, err)
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
func (t *telemetrySink) persistOutcomes(ops []telemetryOp) {
	st := t.store
	if st == nil {
		return
	}
	writeOne := func(op telemetryOp) {
		t.runUnit(func() {
			u := op.update
			err := st.UpdateInferenceRouteOutcome(u.RequestID, u.Attempt, u.Outcome)
			switch {
			case err == nil:
			case t.rowFault(err):
				logRouteOutcomeWriteError(t.logger, u.RequestID, u.Attempt, op.model, u.Outcome, err)
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
