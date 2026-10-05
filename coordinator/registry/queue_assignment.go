package registry

// ProviderAssignment is a prepared reservation handoff. The queue owns cleanup
// until WaitForProviderContext accepts the offer, including while Publish waits
// for a receiver. The preparing owner must call Publish exactly once.
type ProviderAssignment struct {
	request  *QueuedRequest
	provider *Provider
	cleanup  func()
}

// PrepareProviderAssignment transfers reservation cleanup to the queue without
// notifying the waiter. A rejected offer leaves cleanup with the caller.
func (q *RequestQueue) PrepareProviderAssignment(r *QueuedRequest, provider *Provider, cleanup func()) (*ProviderAssignment, bool) {
	r.init()
	r.assignmentMu.Lock()
	defer r.assignmentMu.Unlock()
	select {
	case <-r.DoneCh:
		return nil, false
	default:
	}
	if r.assignment != nil {
		return nil, false
	}
	r.assignment = &ProviderAssignment{request: r, provider: provider, cleanup: cleanup}
	return r.assignment, true
}

// Publish notifies the waiter or releases an offer the waiter canceled. A
// successful send is not acceptance: even after a buffered send, cancellation
// retains responsibility for releasing the reservation exactly once.
func (a *ProviderAssignment) Publish() bool {
	select {
	case a.request.ResponseCh <- a.provider:
		return true
	case <-a.request.Done():
		a.request.rejectAssignment()
		return false
	}
}

// acceptAssignment transfers reservation cleanup from the queue to dispatch.
func (r *QueuedRequest) acceptAssignment(provider *Provider) bool {
	r.assignmentMu.Lock()
	defer r.assignmentMu.Unlock()
	if r.assignment == nil || r.assignment.provider != provider {
		return false
	}
	r.assignment = nil
	return true
}

// rejectAssignment releases a scheduler-owned reservation exactly once. Cleanup
// runs off the assignment lock because it can trigger another queue drain.
func (r *QueuedRequest) rejectAssignment() {
	var cleanup func()
	r.assignmentMu.Lock()
	if r.assignment != nil {
		cleanup = r.assignment.cleanup
		r.assignment = nil
	}
	r.assignmentMu.Unlock()
	if cleanup != nil {
		cleanup()
	}
}
