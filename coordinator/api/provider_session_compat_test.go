package api

import (
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/providercontrol/session"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

const maxProviderVersionLength = session.MaxVersionLength

func (s *Server) applyProviderHeartbeat(id string, provider *registry.Provider, msg *protocol.HeartbeatMessage) bool {
	return s.newProviderSession().ApplyHeartbeat(id, provider, msg)
}

func (s *Server) verificationSubmitPriority(seKey, serial string) store.VerificationPriority {
	return s.newProviderSession().VerificationPriority(seKey, serial)
}
