package registry

// HasCompletionIngress reports whether a clean provider terminal
// (inference_complete) has been ingressed for this attempt. That includes a
// completion parked on the speculative empty-completion decision, which leaves
// the pending record in place: a hedge loser that finished empty on time is
// still "removed != nil" to the dispatcher's cleanup even though nothing is
// running provider-side. Abandon paths consult it before sending a cancel.
func (pr *PendingRequest) HasCompletionIngress() bool {
	if pr == nil {
		return false
	}
	pr.firstContentIngressMu.Lock()
	defer pr.firstContentIngressMu.Unlock()
	return !pr.completionIngressAt.IsZero()
}
