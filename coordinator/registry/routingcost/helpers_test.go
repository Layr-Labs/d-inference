package routingcost

import (
	"testing"
)

var routingPolicy = New[struct{}]()
var ttftCalibration = routingPolicy.calibration

type routingSnapshot = Snapshot[struct{}]

func snapPtr(s routingSnapshot) *routingSnapshot { return &s }

// withTTFTConfig snapshots and restores the package-level Phase-0 TTFT knobs so
// each test runs in isolation (Go runs package tests sequentially, so resetting
// in Cleanup is sufficient).
func withTTFTConfig(t *testing.T, alpha, deadlineBaseMs float64, mode TTFTAdmissionMode) {
	t.Helper()
	prevAlpha := routingPolicy.TTFTOccupancyAlpha()
	prevBase := routingPolicy.TTFTDeadlineBaseMs()
	prevMode := routingPolicy.TTFTAdmissionModeValue()
	t.Cleanup(func() {
		routingPolicy.SetTTFTOccupancyAlpha(prevAlpha)
		routingPolicy.SetTTFTDeadlineBaseMs(prevBase)
		routingPolicy.SetTTFTAdmissionMode(prevMode)
	})
	routingPolicy.SetTTFTOccupancyAlpha(alpha)
	if deadlineBaseMs > 0 {
		routingPolicy.SetTTFTDeadlineBaseMs(deadlineBaseMs)
	}
	routingPolicy.SetTTFTAdmissionMode(mode)
}
