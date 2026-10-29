//go:build native_pair_hardware_experiment

package api

import (
	"context"
	"errors"
	"time"

	"github.com/eigeninference/d-inference/coordinator/registry"
)

// In-process private selector. It waits on read-only eligibility, then calls
// the SAME BeginNativePair once. A refusal after that call is terminal; there
// is no retry/replacement grant, test Provider, trust seed or public API route.
func (s *Server) RunNativeHardwarePair(ctx context.Context, devices [2]registry.NativeHardwareDevice, approvalID string) (registry.NativeHardwareObservation, error) {
	var empty registry.NativeHardwareObservation
	if s.nativePairs == nil {
		return empty, registry.ErrNativePairControl
	}
	selection, cancel := context.WithTimeout(ctx, 60*time.Second)
	defer cancel()
	ticker := time.NewTicker(50 * time.Millisecond)
	defer ticker.Stop()
	var pair *registry.NativePairSession
	for pair == nil {
		if err := selection.Err(); err != nil {
			return empty, err
		}
		members, ready := s.nativePairs.HardwareSelectedMembers(devices, approvalID)
		if ready {
			if err := selection.Err(); err != nil {
				return empty, err
			}
			var err error
			pair, err = s.BeginNativePair(members, approvalID, 300*time.Second)
			if err != nil {
				return empty, err
			}
			break
		}
		select {
		case <-selection.Done():
			return empty, selection.Err()
		case <-ticker.C:
		}
	}
	// Never infer cleanup from Done, cancellation, expiry, or WS writer exit.
	// The original expiry is fixed by Registry; this allowance only observes
	// the existing member's three-second cleanup interval and does not renew it.
	deadline := pair.HardwareObservation().ExpiresAt.Add(3 * time.Second)
	for {
		v := pair.HardwareObservation()
		if v.ReleasedNormally() {
			return v, nil
		}
		if !time.Now().Before(deadline) {
			pair.Cancel()
			return v, errors.New("native hardware pair lacks complete original release evidence")
		}
		select {
		case <-ctx.Done():
			pair.Cancel()
			return pair.HardwareObservation(), ctx.Err()
		case <-ticker.C:
		}
	}
}
