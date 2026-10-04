package trust_test

import (
	"github.com/eigeninference/d-inference/coordinator/api/releases"
	trustreuse "github.com/eigeninference/d-inference/coordinator/internal/provider/reuse"
)

func cachedTrust(c *trustreuse.Cache, seKey, serial, freshBinaryHash string, facts ...releases.ApprovedTransitionFact) (trustreuse.Record, bool) {
	var fact releases.ApprovedTransitionFact
	if len(facts) > 0 {
		fact = facts[0]
	}
	result := c.Decide(trustreuse.Input{
		SEPubKey: seKey, Serial: serial, FreshBinaryHash: freshBinaryHash,
		ReleaseTransition: fact,
	})
	return result.Record, result.Decision != ""
}
