package registry

import "github.com/eigeninference/d-inference/coordinator/internal/registry/deadline"

func (r *Registry) newDeadlinePosture(sessionID string) deadline.PosturePolicy {
	actual := &deadline.Posture{}
	if r.deadlinePostureFactory != nil {
		if policy := r.deadlinePostureFactory(sessionID, actual); policy != nil {
			return policy
		}
	}
	return actual
}

// Caller holds p.mu. Bare Provider values use the same empty session policy.
func (p *Provider) deadlinePostureLocked() deadline.PosturePolicy {
	if p.deadlinePosture == nil {
		p.deadlinePosture = &deadline.Posture{}
	}
	return p.deadlinePosture
}
