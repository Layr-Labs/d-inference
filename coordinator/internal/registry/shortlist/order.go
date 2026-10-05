// Package shortlist owns the bounded order and consumption of dispatch alternates.
package shortlist

const MaxAlternates = 8

// Handle identifies a scan-owned candidate without exposing its provider state.
type Handle struct {
	ProviderID string
	Index      int
}

// Order is serialized by its owning dispatch plan's mutex. Candidate storage
// remains stable while quote ranking and reservations change this order.
type Order struct {
	items  [MaxAlternates]Handle
	count  int
	cursor int
}

func (o *Order) Add(id string, index int) {
	if o.count == MaxAlternates {
		panic("dispatch shortlist exceeds alternate limit")
	}
	o.items[o.count] = Handle{ProviderID: id, Index: index}
	o.count++
}

func (o *Order) Len() int       { return o.count }
func (o *Order) Remaining() int { return o.count - o.cursor }

func (o *Order) Peek() (Handle, bool) {
	if o.cursor == o.count {
		return Handle{}, false
	}
	return o.items[o.cursor], true
}

// Range visits only unconsumed candidates in current quote order.
func (o *Order) Range(visit func(Handle) bool) {
	for i := o.cursor; i < o.count; i++ {
		if !visit(o.items[i]) {
			return
		}
	}
}

// Claim consumes exactly one retained identity. As in the original plan, the
// claimed position is swapped with the head, preserving every other candidate.
func (o *Order) Claim(id string) bool {
	for i := o.cursor; i < o.count; i++ {
		if o.items[i].ProviderID == id {
			o.items[o.cursor], o.items[i] = o.items[i], o.items[o.cursor]
			o.cursor++
			return true
		}
	}
	return false
}

// Rank places a selector's next choice at an offset in the unconsumed tail.
func (o *Order) Rank(id string, offset int) {
	if offset < 0 || offset >= o.Remaining() {
		panic("invalid dispatch rank")
	}
	for i := o.cursor + offset; i < o.count; i++ {
		if o.items[i].ProviderID == id {
			o.items[o.cursor+offset], o.items[i] = o.items[i], o.items[o.cursor+offset]
			return
		}
	}
	panic("dispatch rank is not an unranked alternate")
}
