package registry

import (
	"context"
	"time"
)

type providerRequestAuthorizationBinding struct{ Endpoint, Account, Machine string }

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
	p.mu.Lock()
	w := p.writer
	p.mu.Unlock()
	if w == nil {
		return TextFrameWriteMetadata{}, errProviderWriterStopped
	}
	return w.writeRequest(ctx, &providerWriteRequest{
		builder:     builder,
		beforeWrite: func() error { return p.registry.authorizeInferenceHandoff(p, pending, w) },
	}, false, onHandoff)
}

func (r *Registry) authorizeInferenceHandoff(p *Provider, pending *PendingRequest, writer *providerWriter) error {
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
	if p.writer != writer || p.pendingReqs[pending.RequestID] != pending || pending.ProviderID != p.ID {
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
	return nil
}
