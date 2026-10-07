package inference

import (
	latesettlement "github.com/eigeninference/d-inference/coordinator/internal/inference/settlement"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

// defaultTerminalSettleGrace bounds how long a disconnected request's billing
// record waits for the provider's terminal before its reservation is refunded.
// A connected provider aborts within ms; 30s is a wide WS-latency margin. The
// record lives outside the provider's pending set, so it doesn't count against
// concurrency/idle while waiting.
const DefaultTerminalSettleGrace = latesettlement.DefaultGrace

// holdForSettlement parks a mid-stream-disconnected request for late-terminal
// settlement, refunding its reservation if no terminal arrives within the grace.
func (s *Owner) holdForSettlement(pr *registry.PendingRequest) {
	if s.late == nil {
		fallback := latesettlement.Controller{Refund: s.refundReservedBalance, Outcome: s.updateInferenceRouteOutcomeForPending, NoTerminal: s.NewMetrics().NoTerminal, ClientGone: s.NewMetrics().ClientGone, Logger: s.logger}
		fallback.Hold(pr)
		return
	}
	s.late.Hold(pr)
}

// claimSettlement returns a parked billing record for requestID (consumed), or
// nil. Used by the terminal handlers when the request is no longer in the
// provider's pending set because the consumer already disconnected.
func (s *Owner) claimSettlement(requestID string) *registry.PendingRequest {
	if s.late == nil {
		return nil
	}
	return s.late.Claim(requestID)
}

// observeTTFTCalibration feeds the online TTFT calibrator
// (registry/ttft_calibration.go) with the committed attempt's measured
// dispatch→first-content latency — the same quantity persisted as
// actual_ttft_ms. Called from the dispatch goroutine at content commit
// (commitFirstContent), which owns pr.Timing, so DispatchedAt is safe to read
// directly and FirstContentAt has just been stamped.
//
// Speculative-race attempts (pr.UsedBackup, set on both racers before the race
// starts on this same goroutine) are excluded: the race winner is the faster
// of two draws, which would bias actuals downward. Requests with no matching
// pending prediction (cold dispatches, providers without BackendCapacity,
// retries whose prediction expired) are ignored by the calibrator itself.
func (s *Owner) observeTTFTCalibration(pr *registry.PendingRequest) {
	s.NewMetrics().ObserveTTFTCalibration(pr)
}
