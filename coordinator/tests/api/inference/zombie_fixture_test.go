package inference_test

import cancellation "github.com/eigeninference/d-inference/coordinator/internal/inference/cancellation"

// The fixture retains the real index dependency. Index reads occur only while
// tracker operations are quiescent; the racing test observes Terminal instead.
type zombieFixture struct {
	*cancellation.Tracker
	entries *cancellation.Index
}

func newZombieFixture() *zombieFixture {
	entries := &cancellation.Index{}
	return &zombieFixture{cancellation.NewTracker(entries), entries}
}
