package authority

import (
	"github.com/eigeninference/d-inference/coordinator/store"
)

func (s *Service,

) VerificationSubmitPriority(seKey, serial string) store.VerificationPriority {
	if s.trustReuseCache.HasFreshRecord(seKey, serial) {
		return store.VerificationPriorityRefresh
	}
	return store.VerificationPriorityFirstOrExpired
}
