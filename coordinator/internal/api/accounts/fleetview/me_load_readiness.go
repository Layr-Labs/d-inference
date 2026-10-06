package fleetview

import (
	"math"
	"time"
)

const OwnerHeartbeatTimeoutSeconds = 90

// An owner's attention count uses the same live no-eviction figures as the
// My Macs model-readiness panel. Missing legacy fields never imply a fit or
// a failure; resident slots do not need another load.
func ColdModelLoadBlocked(p *Provider) bool {
	if !p.Online || p.BackendCapacity == nil ||
		p.BackendCapacity.LoadUsableGB == nil || p.BackendCapacity.LoadHeadroomGB == nil ||
		p.BackendCapacity.FreeForLoadGB == nil || p.CapacityAcceptedAt == nil ||
		p.CapacityModelIDs == nil ||
		p.PendingRequests > 0 ||
		(p.BackendCapacity.LoadTransitionActive != nil && *p.BackendCapacity.LoadTransitionActive) {
		return false
	}
	age := time.Since(*p.CapacityAcceptedAt)
	if age < -30*time.Second || age > OwnerHeartbeatTimeoutSeconds*time.Second {
		return false
	}
	usable := *p.BackendCapacity.LoadUsableGB
	headroom := *p.BackendCapacity.LoadHeadroomGB
	if math.IsNaN(usable) || math.IsInf(usable, 0) || usable < 0 ||
		math.IsNaN(headroom) || math.IsInf(headroom, 0) || headroom < 0 {
		return false
	}
	accepted := make(map[string]bool, len(*p.CapacityModelIDs))
	for _, id := range *p.CapacityModelIDs {
		accepted[id] = true
	}
	// Once capacity exists, its slots supersede heartbeat warm/current fields.
	resident := make(map[string]bool, len(p.BackendCapacity.Slots))
	for _, slot := range p.BackendCapacity.Slots {
		if slot.State == "running" || slot.State == "reloading" || slot.NumRunning > 0 || slot.NumWaiting > 0 {
			return false // today's shortage may clear when this request ends
		}
		if slot.State == "idle" || slot.State == "crashed" {
			resident[slot.Model] = true
		}
	}
	for _, model := range p.Models {
		if !accepted[model.ID] || resident[model.ID] || model.EstimatedMemoryGB <= 0 {
			continue
		}
		if model.EstimatedMemoryGB+headroom > usable &&
			*p.BackendCapacity.FreeForLoadGB < model.EstimatedMemoryGB {
			return true
		}
	}
	return false
}
