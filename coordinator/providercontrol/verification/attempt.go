package verification

import "context"

// Attempt carries observations made synchronously by one scheduled verifier.
// The context and the scheduler receive the same pointer, so command callbacks
// and completion classification cannot observe detached copies.
type Attempt struct {
	udid       string
	mdaOutcome string
}

type attemptContextKey struct{}

func NewScheduledAttempt(ctx context.Context) (context.Context, *Attempt) {
	attempt := &Attempt{}
	return context.WithValue(ctx, attemptContextKey{}, attempt), attempt
}

func scheduledAttempt(ctx context.Context) (*Attempt, bool) {
	attempt, ok := ctx.Value(attemptContextKey{}).(*Attempt)
	return attempt, ok
}

func (a *Attempt) UDID() string       { return a.udid }
func (a *Attempt) MDAOutcome() string { return a.mdaOutcome }
