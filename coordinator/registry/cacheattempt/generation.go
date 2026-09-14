package cacheattempt

import "sync/atomic"

// Generation contains no prompt data or receipt maps. Plans may outlive a
// configuration change without retaining the retired generation's evidence.
// Its zero value is active; revocation is permanent.
type Generation struct{ revoked atomic.Bool }

func (g *Generation) Revoke()       { g.revoked.Store(true) }
func (g *Generation) Revoked() bool { return g.revoked.Load() }
