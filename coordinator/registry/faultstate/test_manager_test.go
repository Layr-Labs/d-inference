package faultstate

import (
	"io"
	"log/slog"
	"time"
)

// testManager supplies the former registry recorder entry-point shapes for
// private-state tests with no live Provider. Budget reporting is false there.
// Production registry binds its current budget before the same transactions.
type testManager struct {
	Manager[string]
	versions map[*Session[string]]string
}

func testLogger() *slog.Logger { return slog.New(slog.NewTextHandler(io.Discard, nil)) }
func newTestManager(logger *slog.Logger) *testManager {
	return &testManager{Manager: New[string](logger)}
}
func (r *testManager) RecordCapacityReject(id, model string) bool {
	return r.Manager.RecordCapacityReject(id, model, true, true, false)
}
func (r *testManager) RecordCapacityRejectLifecycle(id, model string) bool {
	return r.Manager.RecordCapacityReject(id, model, false, false, false)
}
func (r *testManager) RecordCapacityAccept(id, model string) bool {
	return r.RecordCapacityAcceptObserved(id, model, time.Now(), true)
}
func (r *testManager) RecordCapacityAcceptOutcome(id, model string, count bool) bool {
	return r.RecordCapacityAcceptObserved(id, model, time.Now(), count)
}
func (r *testManager) RecordCapacityAcceptObserved(id, model string, observed time.Time, count bool) bool {
	accept, ok := r.PrepareCapacityAccept(id, model, observed, count)
	if !ok {
		return false
	}
	return accept.Apply(time.Time{}, 0, false)
}
func (r *testManager) gateCount() int           { return r.Count() }
func (r *testManager) sweepGates(now time.Time) { r.Sweep(now) }
func (r *testManager) capacityCooled(id, model string, now time.Time) bool {
	return r.CapacityCooled(id, model, now)
}
func (r *testManager) capacityRatePenalty(id, model string, now time.Time) (float64, float64) {
	return r.CapacityRatePenalty(id, model, now)
}
func (r *testManager) dispatchLoadCooled(id, model string, now time.Time) bool {
	return r.DispatchLoadCooled(id, model, now)
}
func (r *testManager) inferenceErrorCooled(id, model, shape string, now time.Time) bool {
	return r.InferenceErrorCooled(id, model, shape, now)
}
func claimCapacityProbe(r *testManager, id, model string) bool {
	return r.claimCapacityProbeRef(r.gateForSession(id), model, time.Now())
}

func cooldownActive(r *testManager, providerID, modelID string, now time.Time) bool {
	return r.dispatchLoadCooled(providerID, modelID, now)
}

func inferenceCooldownActiveAt(r *testManager, providerID, modelID, shape string, now time.Time) bool {
	return r.inferenceErrorCooled(providerID, modelID, shape, now)
}
