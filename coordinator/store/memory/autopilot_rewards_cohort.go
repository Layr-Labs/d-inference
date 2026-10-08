package memory

import (
	"context"
	"errors"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/payments/floorpolicy"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/earningsfloor"
)

// Caller has already proved the first-ever opt-in anchor from the complete
// consent journal. Missing historical consent must never become a new-machine
// cohort baseline merely because today's inventory is recent.
func (s *MemoryStore) autopilotRewardBaselineLocked(ctx context.Context, machine autopilotRewardMachine, anchor time.Time) (int64, string, string, error) {
	start := anchor.Add(-floorpolicy.BaselineDuration)
	if !machine.firstSeen.After(start) {
		total, err := s.autopilotRewardInferenceLocked(ctx, machine, start, anchor)
		if err != nil {
			return 0, "", "", err
		}
		return total, earningsfloor.TrackedBaseline, "tracked_inference_history", nil
	}
	key, known := s.autopilotRewardTargetCohortKeyLocked(machine, anchor)
	if !known {
		return 0, "", "", earningsfloor.ErrHistory
	}
	peers := make(map[string]int64)
	for id := range s.machineInventory.Machines {
		if machine.aliases[id] {
			continue
		}
		peer, err := s.autopilotRewardMachineLocked(id)
		if errors.Is(err, earningsfloor.ErrIdentity) || errors.Is(err, earningsfloor.ErrHistory) || errors.Is(err, store.ErrErasureConflict) {
			continue
		}
		if err != nil {
			return 0, "", "", err
		}
		if peer.id == machine.id || peer.firstSeen.After(start) {
			continue
		}
		peerKey, known := s.autopilotRewardCohortKeyLocked(peer, anchor)
		if !known || peerKey != key {
			continue
		}
		total, err := s.autopilotRewardInferenceLocked(ctx, peer, start, anchor)
		if errors.Is(err, earningsfloor.ErrIdentity) || errors.Is(err, earningsfloor.ErrHistory) {
			continue
		}
		if err != nil {
			return 0, "", "", err
		}
		peers[peer.id] = total
	}
	total, evidence, err := floorpolicy.CohortBaselineValue(key, anchor, peers)
	if err != nil {
		return 0, "", "", err
	}
	return total, earningsfloor.CohortBaseline, evidence, nil
}

// The original declaration contains registration hardware before asynchronous
// inventory binding. Later hardware and retry timestamps cannot select a new
// target cohort. Older journals without that snapshot use historical inventory.
func (s *MemoryStore) autopilotRewardTargetCohortKeyLocked(machine autopilotRewardMachine, anchor time.Time) (floorpolicy.CohortKey, bool) {
	var key floorpolicy.CohortKey
	known := false
	for session := range machine.sessions {
		for _, event := range s.autopilotRewardConsents[session].events {
			if !event.At.Equal(anchor) || !event.Supported || !event.OptedIn || event.Chip == "" && event.MemoryGB == 0 {
				continue
			}
			candidate, valid := floorpolicy.ParseCohortKey(event.Chip, event.MemoryGB)
			if !valid || known && candidate != key {
				return floorpolicy.CohortKey{}, false
			}
			key, known = candidate, true
		}
	}
	if known {
		return key, true
	}
	return s.autopilotRewardCohortKeyLocked(machine, anchor)
}

// Memory inventory keeps only each session's latest observation. If that
// observation postdates the anchor, the earlier hardware cannot be recovered;
// fail closed instead of importing changed hardware into a frozen baseline.
func (s *MemoryStore) autopilotRewardCohortKeyLocked(machine autopilotRewardMachine, anchor time.Time) (floorpolicy.CohortKey, bool) {
	var key floorpolicy.CohortKey
	known := false
	for session := range machine.sessions {
		if s.machineInventory.SessionFirstSeen[session].After(anchor) {
			continue
		}
		observation := s.machineInventory.Sessions[session]
		if observation.At.After(anchor) {
			return floorpolicy.CohortKey{}, false
		}
		candidate, valid := floorpolicy.ParseCohortKey(observation.Chip, observation.MemoryGB)
		if !valid || known && candidate != key {
			return floorpolicy.CohortKey{}, false
		}
		key, known = candidate, true
	}
	return key, known
}
