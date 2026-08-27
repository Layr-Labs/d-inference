package registry

import (
	"testing"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func TestSnapshotRouteCandidatesRanksWinnerAndKeepsRejects(t *testing.T) {
	cheap := &Provider{ID: "cheap"}
	slow := &Provider{ID: "slow"}
	full := &Provider{ID: "full"}
	winner := &routingCandidate{
		provider: cheap,
		costMs:   800,
		snapshot: routingSnapshot{
			provider:       cheap,
			chipFamily:     "M4",
			hardwareTier:   "Max",
			memoryGB:       64,
			slotState:      "idle",
			decodeTPS:      50,
			backendRunning: 1,
			systemMetrics:  protocol.SystemMetrics{MemoryPressure: 0.2, ThermalState: "nominal"},
		},
		effectiveQueue: 1,
		effectiveTPS:   45,
		breakdown:      costBreakdown{QueueMs: 100, ThisReqMs: 700, Total: 800},
	}
	loser := &routingCandidate{
		provider: slow,
		costMs:   2400,
		snapshot: routingSnapshot{
			provider:     slow,
			chipFamily:   "M3",
			hardwareTier: "Pro",
			memoryGB:     36,
			slotState:    "running",
			decodeTPS:    20,
		},
		effectiveQueue: 3,
		effectiveTPS:   12,
		breakdown:      costBreakdown{HealthMs: 800, ThisReqMs: 1600, Total: 2400},
	}
	scan := candidateScan{
		pool: []*routingCandidate{loser, winner},
		rejected: []rejectedCandidate{{
			snap: routingSnapshot{
				provider:  full,
				memoryGB:  24,
				slotState: "running",
			},
			reason: store.CandidateRejectCapacity,
		}},
	}

	got := snapshotRouteCandidates(winner, scan, true)
	if len(got) != 3 {
		t.Fatalf("snapshots = %d, want 3", len(got))
	}
	if got[0].ProviderID != "cheap" || got[0].Rank != 0 || !got[0].Selected || !got[0].Eligible {
		t.Fatalf("winner row = %+v", got[0])
	}
	if got[1].ProviderID != "slow" || got[1].Rank != 1 || got[1].Selected {
		t.Fatalf("runner-up row = %+v", got[1])
	}
	if got[2].ProviderID != "full" || got[2].Rank != -1 || got[2].Eligible || got[2].RejectionReason != store.CandidateRejectCapacity {
		t.Fatalf("rejected row = %+v", got[2])
	}

	notReserved := snapshotRouteCandidates(winner, scan, false)
	if notReserved[0].Selected {
		t.Fatal("unreserved winner must not be marked selected")
	}
}

func TestSnapshotRouteCandidatesEmpty(t *testing.T) {
	if got := snapshotRouteCandidates(nil, candidateScan{}, false); len(got) != 0 {
		t.Fatalf("empty scan snapshots = %d", len(got))
	}
}

func TestSnapshotRouteCandidatesKeepsSoftFilterRejects(t *testing.T) {
	owned := &Provider{ID: "owned"}
	public := &Provider{ID: "public"}
	winner := &routingCandidate{
		provider:  owned,
		costMs:    2000,
		snapshot:  routingSnapshot{provider: owned, decodeTPS: 20},
		breakdown: costBreakdown{Total: 2000},
	}
	filtered := &routingCandidate{
		provider:  public,
		costMs:    800,
		snapshot:  routingSnapshot{provider: public, decodeTPS: 80},
		breakdown: costBreakdown{Total: 800},
	}
	scan := candidateScan{
		pool: []*routingCandidate{winner},
		rejected: []rejectedCandidate{{
			candidate: filtered,
			snap:      filtered.snapshot,
			reason:    store.CandidateRejectPreferOwner,
		}},
	}
	got := snapshotRouteCandidates(winner, scan, true)
	if len(got) != 2 {
		t.Fatalf("snapshots = %d, want 2", len(got))
	}
	var sawSoft bool
	for _, row := range got {
		if row.ProviderID == "public" {
			sawSoft = true
			if row.Eligible || row.RejectionReason != store.CandidateRejectPreferOwner || row.CostMs != 800 {
				t.Fatalf("soft-filtered row = %+v", row)
			}
		}
		if row.ProviderID == "owned" && (!row.Selected || !row.Eligible) {
			t.Fatalf("owned winner row = %+v", row)
		}
	}
	if !sawSoft {
		t.Fatal("soft-filtered public candidate missing")
	}
}
