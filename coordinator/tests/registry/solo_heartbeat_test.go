package registry_test

import (
	"testing"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	production "github.com/eigeninference/d-inference/coordinator/registry"
)

const gptossBuild = "gpt-oss-20b"

func soloHeartbeat(slots []protocol.BackendSlotCapacity) *protocol.HeartbeatMessage {
	return &protocol.HeartbeatMessage{
		Type: protocol.TypeHeartbeat, Status: "serving",
		BackendCapacity: &protocol.BackendCapacity{TotalMemoryGB: 64, Slots: slots},
	}
}

// TestSoloRecordingGatedOnUncontendedBox drives the REAL heartbeat ingest
// path: a slot EWMA becomes a solo sample only when the whole box has at most
// one running-or-waiting request (the sample-generating request itself) AND
// the slot is the one running it. Any co-resident activity — another model
// running, or waiting queue depth — disqualifies the sample, and a fully idle
// box records nothing (a decayed EWMA with no active request is not a fresh
// observation); the load-inclusive store records regardless.
func TestSoloRecordingGatedOnUncontendedBox(t *testing.T) {
	throughput := production.NewTPSRegistry()
	reg := production.NewWithDependencies(testLogger(), production.Dependencies{Throughput: throughput})
	makeSchedulerProvider(t, reg, "box", gemmaBuild, 93, gptossBuild)

	// Uncontended: gemma serving exactly the sample-generating request.
	// Solo samples are keyed by chip CLASS ("M3|Max"), not family ("M3").
	reg.Heartbeat("box", soloHeartbeat([]protocol.BackendSlotCapacity{
		{Model: gemmaBuild, State: "running", NumRunning: 1, ObservedDecodeTPS: 14},
		{Model: gptossBuild, State: "idle", NumRunning: 0, NumWaiting: 0},
	}))
	if _, n := throughput.SoloMedian(gemmaBuild, "M3|Max"); n != 1 {
		t.Fatalf("solo samples after uncontended heartbeat = %d, want 1", n)
	}

	// Fully idle box: the reported EWMA is a stale decayed value with no
	// request behind it — NOT a fresh solo observation. Recording it would let
	// an idle box mint one bogus sample per heartbeat.
	reg.Heartbeat("box", soloHeartbeat([]protocol.BackendSlotCapacity{
		{Model: gemmaBuild, State: "idle", ObservedDecodeTPS: 15},
	}))
	if _, n := throughput.SoloMedian(gemmaBuild, "M3|Max"); n != 1 {
		t.Fatalf("solo samples after idle heartbeat = %d, want 1 (idle EWMA must not be recorded)", n)
	}

	// Co-resident model busy → gemma's EWMA is a contended rate: NOT solo.
	reg.Heartbeat("box", soloHeartbeat([]protocol.BackendSlotCapacity{
		{Model: gemmaBuild, State: "running", NumRunning: 1, ObservedDecodeTPS: 5},
		{Model: gptossBuild, State: "running", NumRunning: 1, ObservedDecodeTPS: 40},
	}))
	// Same-slot queue depth also disqualifies (batch of 2 on one model).
	reg.Heartbeat("box", soloHeartbeat([]protocol.BackendSlotCapacity{
		{Model: gemmaBuild, State: "running", NumRunning: 1, NumWaiting: 1, ObservedDecodeTPS: 6},
	}))
	if _, n := throughput.SoloMedian(gemmaBuild, "M3|Max"); n != 1 {
		t.Fatalf("solo samples after contended heartbeats = %d, want 1 (contended samples must be rejected)", n)
	}
	// The load-inclusive store keeps EVERY sample (TTFT estimation semantics).
	if got := throughput.Median(gemmaBuild, "M3"); got != (6+14)/2.0 {
		t.Fatalf("load-inclusive median = %v, want 10 (all four gemma samples recorded: 14,15,5,6)", got)
	}
}

// TestSoloRecordingOnlySamplesActiveSlot is the idle-co-resident contamination
// regression: with model A running the box's ONE active request, model B's
// idle slot keeps re-reporting its stale decayed EWMA in every heartbeat.
// Only A may be sampled — otherwise B accumulates one duplicate "solo"
// sample per ~30s heartbeat from a single long-past observation, reaches the
// min-sample trust floor without any real measurement, and B's quality cap is
// then derived from a rate no request produced.
func TestSoloRecordingOnlySamplesActiveSlot(t *testing.T) {
	throughput := production.NewTPSRegistry()
	reg := production.NewWithDependencies(testLogger(), production.Dependencies{Throughput: throughput})
	makeSchedulerProvider(t, reg, "box", gemmaBuild, 93, gptossBuild)

	for i := 0; i < 5; i++ {
		reg.Heartbeat("box", soloHeartbeat([]protocol.BackendSlotCapacity{
			{Model: gemmaBuild, State: "running", NumRunning: 1, ObservedDecodeTPS: 14},
			{Model: gptossBuild, State: "idle", ObservedDecodeTPS: 60}, // stale EWMA, no request
		}))
	}
	if _, n := throughput.SoloMedian(gemmaBuild, "M3|Max"); n != 5 {
		t.Fatalf("active-slot solo samples = %d, want 5", n)
	}
	if _, n := throughput.SoloMedian(gptossBuild, "M3|Max"); n != 0 {
		t.Fatalf("idle co-resident slot recorded %d solo samples, want 0 (stale EWMA contamination)", n)
	}
	// The load-inclusive store still sees both slots' EWMAs.
	if got := throughput.Median(gptossBuild, "M3"); got != 60 {
		t.Fatalf("load-inclusive median for idle slot = %v, want 60", got)
	}
}

// TestSoloRecordingRequiresRunningDecode is the queued-but-not-running
// regression (Finding 3 of the final round): a box with one QUEUED request and
// no running decode is box-wide uncontended (soloEligible), and the owning slot
// has NumWaiting > 0 — but its ObservedDecodeTPS is a retained EWMA with no
// running decode behind it. The prior round's NumRunning+NumWaiting > 0 gate
// would mint that stale EWMA as a fresh solo sample every heartbeat; the
// tightened NumRunning > 0 gate must not. A running-and-uncontended heartbeat
// still records. Fails without the NumRunning > 0 gate in the heartbeat ingest.
func TestSoloRecordingRequiresRunningDecode(t *testing.T) {
	throughput := production.NewTPSRegistry()
	reg := production.NewWithDependencies(testLogger(), production.Dependencies{Throughput: throughput})
	makeSchedulerProvider(t, reg, "box", gemmaBuild, 93)

	// Queued but NOT decoding: NumRunning 0 / NumWaiting 1. Box-wide load = 1
	// (uncontended), but observed_decode_tps is a stale retained EWMA — no
	// running request produced it, so it must NOT be sampled.
	reg.Heartbeat("box", soloHeartbeat([]protocol.BackendSlotCapacity{
		{Model: gemmaBuild, State: "running", NumRunning: 0, NumWaiting: 1, ObservedDecodeTPS: 14},
	}))
	if _, n := throughput.SoloMedian(gemmaBuild, "M3|Max"); n != 0 {
		t.Fatalf("solo samples after queued-but-not-running heartbeat = %d, want 0 (stale EWMA, no running decode)", n)
	}

	// Running and uncontended: NumRunning 1 / NumWaiting 0 → a real solo sample.
	reg.Heartbeat("box", soloHeartbeat([]protocol.BackendSlotCapacity{
		{Model: gemmaBuild, State: "running", NumRunning: 1, NumWaiting: 0, ObservedDecodeTPS: 12},
	}))
	if _, n := throughput.SoloMedian(gemmaBuild, "M3|Max"); n != 1 {
		t.Fatalf("solo samples after running-uncontended heartbeat = %d, want 1", n)
	}
	// The load-inclusive store records BOTH heartbeats' EWMAs regardless.
	if got := throughput.Median(gemmaBuild, "M3"); got != (12+14)/2.0 {
		t.Fatalf("load-inclusive median = %v, want 13 (both EWMAs recorded: 14, 12)", got)
	}
}
