package inference

import (
	"time"

	cancellation "github.com/eigeninference/d-inference/coordinator/internal/inference/cancellation"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

func (s *Owner) cancellationController() *cancellation.Controller {
	if s.cancels != nil {
		return s.cancels
	}
	return &cancellation.Controller{Registry: s.registry, Store: s.store, Observation: s.observation, Logger: s.logger}
}

func (s *Owner) sendProviderCancel(p *registry.Provider, id string) bool {
	return s.cancellationController().SendProviderCancel(p, id)
}

func (s *Owner) cancelDispatch(p *registry.Provider, pr *registry.PendingRequest, cause string) {
	s.cancellationController().CancelDispatch(p, pr, cause)
}

func (s *Owner) cancelDispatchAfterTerminal(p *registry.Provider, pr *registry.PendingRequest) {
	s.cancellationController().CancelDispatchAfterTerminal(p, pr)
}

func (s *Owner) cancelDispatchForFirstContentTimeout(p *registry.Provider, pr *registry.PendingRequest) bool {
	return s.cancellationController().CancelDispatchForFirstContentTimeout(p, pr)
}

func (s *Owner) refundProviderExtra(pr *registry.PendingRequest) {
	s.cancellationController().RefundProviderExtra(pr)
}

func (s *Owner) sendAbandonCancel(p *registry.Provider, id, model, cause string) {
	s.cancellationController().SendAbandonCancel(p, id, model, cause)
}

func (s *Owner) sendRecordedCancel(p *registry.Provider, id, model, cause string) {
	s.cancellationController().SendRecordedCancel(p, id, model, cause)
}

func (s *Owner) noteStrayChunk(p *registry.Provider, providerID, id string, now time.Time) {
	s.cancellationController().NoteStrayChunk(p, providerID, id, now)
}

func (s *Owner) resolveCancelledTerminal(id, terminal, outcome string, now time.Time) (cancellation.Entry, bool) {
	return s.cancellationController().ResolveCancelledTerminal(id, terminal, outcome, now)
}

func (s *Owner) emitExpiredCancelEntries(entries []cancellation.Entry) {
	s.cancellationController().EmitExpiredCancelEntries(entries)
}

func (s *Owner) emitUnknownFrame(kind string, p *registry.Provider) {
	if s != nil {
		s.cancellationController().EmitUnknownFrame(kind, p)
	}
}
