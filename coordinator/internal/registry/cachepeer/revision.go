// Package cachepeer fences cache evidence across capability publication. The
// owning provider serializes Capture, Accepts and Advance with its existing lock.
package cachepeer

type Revision struct{ sequence uint64 }

// Token is an immutable capability-publication identity, not a counter snapshot.
// Its owner binding prevents a token from crossing provider revisions.
type Token struct {
	owner    *Revision
	sequence uint64
}

func NewRevision() *Revision { return &Revision{} }

func (r *Revision) Capture() Token {
	if r == nil {
		return Token{}
	}
	return Token{owner: r, sequence: r.sequence}
}

func (r *Revision) Accepts(token Token) bool { return r.Capture() == token }
func (r *Revision) Advance()                 { r.sequence++ }
