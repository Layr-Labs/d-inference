// Package eviction owns consecutive-sweep grace accounting and sweep diagnostics.
package eviction

// Threshold gives a stale provider one sweep to recover before eviction.
const Threshold = 2

// Grace carries only providers awaiting their second consecutive stale sweep.
// The connection lifecycle holds its registry lock around all operations.
type Grace struct {
	strikes map[string]int
}

func (g *Grace) Count() int { return len(g.strikes) }

func (g *Grace) Consecutive(id string) int { return g.strikes[id] }

// Sweep accumulates a replacement without changing the previous sweep while
// the lifecycle scans under its read lock.
type Sweep struct {
	previous *Grace
	next     map[string]int
}

func (g *Grace) Begin() Sweep { return Sweep{previous: g} }

func (s *Sweep) ObserveStale(id string) int {
	strikes := s.previous.Consecutive(id) + 1
	if strikes < Threshold {
		if s.next == nil {
			s.next = make(map[string]int)
		}
		s.next[id] = strikes
	}
	return strikes
}

func (s *Sweep) Count() int { return len(s.next) }

// Commit installs the complete sweep under the lifecycle's write lock. Fresh
// and disconnected providers are absent, so their previous strikes disappear.
func (g *Grace) Commit(s Sweep) { g.strikes = s.next }
