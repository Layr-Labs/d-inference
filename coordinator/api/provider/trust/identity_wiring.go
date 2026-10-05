package trust

import (
	codeidentity "github.com/eigeninference/d-inference/coordinator/internal/provider/identity"
	identitystate "github.com/eigeninference/d-inference/coordinator/internal/provider/identity/state"
)

func newCodeAttestThrottle() *codeidentity.Throttle {
	return codeidentity.NewThrottle(identitystate.NewPolicy(CodeAttestResponseTimeout, ChallengeResponseTimeout))
}
