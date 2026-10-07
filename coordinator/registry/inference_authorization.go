package registry

import (
	"context"
	"time"

	providerwrite "github.com/eigeninference/d-inference/coordinator/internal/registry/providerwrite"
)

type providerRequestAuthorizationBinding struct{ Endpoint, Account, Machine string }

// InferenceHandoff freezes the writer and reservation identity of one attempt.
// Authorization and a definitive abort operate on that same attempt even when
// a caller has already removed the pending request or begun a retry.
type InferenceHandoff struct {
	provider      *Provider
	pending       *PendingRequest
	writer        *providerwrite.Writer
	reservationID string
}

func (p *Provider) NewInferenceHandoff(pending *PendingRequest) InferenceHandoff {
	if p == nil || pending == nil {
		return InferenceHandoff{}
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	return InferenceHandoff{provider: p, pending: pending, writer: p.writer, reservationID: pending.ServiceReservationID()}
}

func providerRequestAuthorizationBindingLocked(p *Provider) providerRequestAuthorizationBinding {
	binding := providerRequestAuthorizationBinding{Endpoint: p.PublicKey, Account: p.AccountID}
	if p.verifiedMachineAccount == p.AccountID {
		binding.Machine = p.verifiedMachineID
	}
	return binding
}

// WriteInferenceTextDeferred is the required final handoff for every private
// inference dispatch (direct, queued, cold, retry and hedge). Selection and
// reservation can precede an expiry, revocation or connection replacement, so
// the writer rechecks after its queue, frame builder and owner acknowledgment.
//
// Linearization: a successful beforeWrite check commits this frame as an
// in-flight dispatch under registry/provider locks. Locks are then released
// before any network I/O. A later invalidation fences subsequent handoffs; it
// cannot recall this already committed frame or plaintext already delivered.
// onHandoff acknowledges preparation only; callers publish dispatch accounting
// from the returned metadata.Committed, never from that provisional callback.
// Control/recovery traffic continues through the ordinary writer methods.
func (p *Provider) WriteInferenceTextDeferred(
	ctx context.Context, pending *PendingRequest,
	builder TextFrameBuilder, onHandoff TextFrameHandoff,
) (TextFrameWriteMetadata, error) {
	if p == nil || p.registry == nil || pending == nil || builder == nil {
		return TextFrameWriteMetadata{}, ErrProviderServingUnauthorized
	}
	handoff := p.NewInferenceHandoff(pending)
	if handoff.writer == nil {
		return TextFrameWriteMetadata{}, errProviderWriterStopped
	}
	metadata, err := handoff.writer.WriteRequest(ctx, providerwrite.NewDeferred(builder,
		func() error { return handoff.Authorize() }), false, onHandoff)
	if !metadata.Committed {
		// The writer proves no frame reached the wire, including cancellation
		// after authorization but before its final in-flight CAS.
		handoff.Abort()
	}
	return metadata, err
}

func (h InferenceHandoff) Authorize() error {
	p, pending, writer, reservationID := h.provider, h.pending, h.writer, h.reservationID
	if p == nil || p.registry == nil || pending == nil {
		return ErrProviderServingUnauthorized
	}
	r := p.registry
	r.mu.RLock()
	defer r.mu.RUnlock()
	if r.providers[p.ID] != p {
		return ErrProviderServingUnauthorized
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	// A final handoff cannot use a clock sampled before a contended lock:
	// the authorization may have expired while this writer was waiting.
	now := time.Now()
	if providerDrainingLocked(p, now) {
		return ErrProviderDraining
	}
	if p.writer != writer || p.pendingReqs[pending.RequestID] != pending || pending.ProviderID != p.ID || pending.ServiceReservationID() != reservationID || pending.serviceHandoffAborted {
		return ErrProviderServingUnauthorized
	}
	if pending.providerAuthorizationBinding != providerRequestAuthorizationBindingLocked(p) {
		return ErrProviderServingUnauthorized
	}
	owned := pending.OwnerAccountID != "" && pending.OwnerAccountID == p.AccountID
	selfRouteOwner := owned && (pending.SelfRouteOnly || pending.PreferOwner)
	if pending.SelfRouteOnly && !owned {
		return ErrProviderServingUnauthorized
	}
	minimum := r.MinTrustLevel
	if selfRouteOwner {
		minimum = TrustNone
	}
	if !r.providerLivenessGateLocked(p, minimum, selfRouteOwner, now) ||
		!r.providerServesRoutableModelLocked(p, pending.Model, selfRouteOwner) ||
		!r.providerEligibleForTraitsLocked(p, pending.Model, pending.Traits) {
		return ErrProviderServingUnauthorized
	}
	pending.DispatchVerification = r.providerVerificationLocked(p, now)
	// Capability may arrive while this reservation waits in the writer queue.
	// Freeze retirement tracking at the authorized handoff, under the same lock
	// as heartbeat opt-in. Already handed-off attempts are never upgraded by a
	// later heartbeat: their release proof could have arrived before opt-in.
	pending.serviceRetirementTracked = p.serviceRetirementProtocol
	pending.serviceHandoffAuthorized = true
	return nil
}
