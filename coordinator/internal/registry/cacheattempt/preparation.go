package cacheattempt

import "sync/atomic"

// Preparation owns one request's publication cursor. Begin, Publish, Accepts,
// and Close require caller serialization, shared with legacy-body metadata.
// Snapshot and Participates may run concurrently with those transitions.
type Preparation struct {
	owner  atomic.Pointer[Owner]
	ticket uint64
	closed bool
}

// Ticket identifies one preparation without exposing its publication cursor.
type Ticket struct{ sequence uint64 }

// Retirement defers receipt-store work until the caller releases its request
// lock. Revocation itself has already happened at the preparation transition.
type Retirement struct {
	owner    *Owner
	terminal bool
}

func (r Retirement) Complete() {
	if r.owner == nil {
		return
	}
	if r.terminal {
		r.owner.TerminalReceipt()
	} else {
		r.owner.ForgetReceipt()
	}
}

func (p *Preparation) Begin() (Ticket, bool, Retirement) {
	owner := p.owner.Swap(nil)
	if owner != nil {
		owner.Revoke()
	}
	p.ticket++
	return Ticket{sequence: p.ticket}, !p.closed, Retirement{owner: owner}
}

func (p *Preparation) Accepts(ticket Ticket) bool {
	return !p.closed && p.ticket == ticket.sequence
}

func (p *Preparation) Publish(ticket Ticket, owner *Owner) bool {
	if !p.Accepts(ticket) {
		return false
	}
	p.owner.Store(owner)
	return true
}

func (p *Preparation) Close() Retirement {
	p.closed = true
	p.ticket++
	owner := p.owner.Load()
	if owner != nil {
		owner.Revoke()
	}
	return Retirement{owner: owner, terminal: true}
}

func (p *Preparation) Snapshot() Snapshot { return Snapshot{owner: p.owner.Load()} }

func (p *Preparation) Participates() bool { return p.owner.Load().Participates() }
