package registry

import (
	"time"
)

// AddPending registers a pending request on this provider.
func (p *Provider) AddPending(pr *PendingRequest) {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.addPendingLocked(pr)
}

// addPendingLocked registers a pending request. Caller must hold p.mu.
func (p *Provider) addPendingLocked(pr *PendingRequest) {
	p.pendingReqs[pr.RequestID] = pr
}

// RemovePending removes and returns a pending request.
func (p *Provider) RemovePending(requestID string) *PendingRequest {
	p.mu.Lock()
	pr := p.removePendingLocked(requestID)
	p.mu.Unlock()
	if pr != nil && p.registry != nil {
		p.registry.MarkCacheAttemptTerminal(pr)
	}
	return pr
}

// RemovePendingForFirstContentTimeout atomically rechecks provider ingress
// while holding pending ownership. deferred is true when an on-time event won
// the deadline race and timeout cleanup must wait for its delivery/settlement.
func (p *Provider) RemovePendingForFirstContentTimeout(
	requestID string,
) (pr *PendingRequest, deferred bool) {
	p.mu.Lock()
	pr = p.pendingReqs[requestID]
	if pr != nil && pr.FirstContentIngressArrivedByDeadline() {
		p.mu.Unlock()
		return nil, true
	}
	if pr != nil {
		pr = p.removePendingLocked(requestID)
	}
	p.mu.Unlock()
	if pr != nil && p.registry != nil {
		p.registry.MarkCacheAttemptTerminal(pr)
	}
	return pr, false
}

// removePendingLocked removes and returns a pending request. Caller must hold p.mu.
func (p *Provider) removePendingLocked(requestID string) *PendingRequest {
	pr := p.pendingReqs[requestID]
	delete(p.pendingReqs, requestID)
	return pr
}

// GetPending retrieves a pending request without removing it.
func (p *Provider) GetPending(requestID string) *PendingRequest {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.pendingReqs[requestID]
}

// BeginPendingChunkIngress atomically resolves pending ownership and publishes
// the chunk-ingress marker against concurrent RemovePending cleanup.
func (p *Provider) BeginPendingChunkIngress(requestID string) (*PendingRequest, time.Time) {
	p.mu.Lock()
	defer p.mu.Unlock()
	pr := p.pendingReqs[requestID]
	if pr == nil {
		return nil, time.Time{}
	}
	return pr, pr.BeginProviderChunkIngress()
}

// MarkPendingCompletionIngressNow atomically resolves pending ownership and
// publishes completion ingress before asynchronous settlement.
func (p *Provider) MarkPendingCompletionIngressNow(
	requestID string,
) (*PendingRequest, time.Time) {
	p.mu.Lock()
	defer p.mu.Unlock()
	pr := p.pendingReqs[requestID]
	if pr == nil {
		return nil, time.Time{}
	}
	return pr, pr.MarkCompletionIngressNow()
}

// pendingCount returns the number of in-flight requests.
// Caller must hold p.mu.
func (p *Provider) pendingCount() int {
	return len(p.pendingReqs)
}

// PendingCount returns the number of in-flight requests (thread-safe).
func (p *Provider) PendingCount() int {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.pendingCount()
}
