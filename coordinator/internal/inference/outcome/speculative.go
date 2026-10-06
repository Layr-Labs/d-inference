package outcome

import "github.com/eigeninference/d-inference/coordinator/registry"

func (r *Recorder) SpeculativeLoser(pr *registry.PendingRequest) {
	if pr == nil {
		return
	}
	pr.UsedBackup.Store(true)
	r.Pending(pr, SpeculativeLoserOutcome(pr))
}
