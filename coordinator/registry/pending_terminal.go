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

// NoteChunkOverflowGrace records that the chunk relay is about to spend an
// overflow grace window (api.chunkOverflowGrace) on this request and reports
// whether it is the FIRST such window. The candidate policy is one window per
// request — a consumer that falls a full buffer behind twice in one stream is
// stuck, not bursty, and every further window stalls the provider's single
// read goroutine for its other streams — but this pass only measures how often
// a second window is spent (inference.chunk_overflow_grace{outcome:would_skip});
// the relay still grants it.
func (pr *PendingRequest) NoteChunkOverflowGrace() (first bool) {
	if pr == nil {
		return false
	}
	return pr.overflowGraceUsed.CompareAndSwap(false, true)
}
