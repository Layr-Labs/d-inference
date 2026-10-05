package storage

// Scope belongs to one serialized session worker. Nested evidence/events reuse
// its permit; unrelated sessions share only the bounded Budget.
type Scope struct {
	budget *Budget
	held   bool
}

func NewScope(budget *Budget) *Scope { return &Scope{budget: budget} }

func (s *Scope) Acquire() (func(), bool) {
	if s.held {
		return func() {}, true
	}
	release, ok := s.budget.AcquireProof()
	if !ok {
		return nil, false
	}
	s.held = true
	return func() { s.held = false; release() }, true
}
