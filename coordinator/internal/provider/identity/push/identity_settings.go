package push

import (
	"github.com/eigeninference/d-inference/coordinator/apns"
)

func (s *Dispatcher,

) SetCodeAttestor(a apns.CodeIdentityAttestor) {
	s.codeAttestor = a
	s.registry.SetCodeAttestationConfigured(a != nil)
}
