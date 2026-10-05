package connectiontime

import "time"

// Origin is the immutable creation order and age of one provider connection.
type Origin struct {
	at time.Time
}

func New(at time.Time) *Origin { return &Origin{at: at} }

// Time returns the immutable creation time, or zero for an unknown origin.
func (o *Origin) Time() time.Time {
	if o == nil {
		return time.Time{}
	}
	return o.at
}

// Age retains full duration precision; an undated connection has unknown age.
func (o *Origin) Age(now time.Time) (time.Duration, bool) {
	if o == nil || o.at.IsZero() {
		return 0, false
	}
	return now.Sub(o.at), true
}

// NewerThan arbitrates equal creation times deterministically by session ID.
func (o *Origin) NewerThan(other *Origin, id, otherID string) bool {
	var at, otherAt time.Time
	if o != nil {
		at = o.at
	}
	if other != nil {
		otherAt = other.at
	}
	return at.After(otherAt) || (at.Equal(otherAt) && id > otherID)
}
