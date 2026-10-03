package inference

import (
	"errors"
	"net/http"
	"strings"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api/access"
	"github.com/eigeninference/d-inference/coordinator/modelpolicy"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// Exact account IDs or stored account emails, configured by the operator.
// Request headers, model aliases and the generic service role are not identity.
func (s *Owner) accountHasFirstContentSLA(accountID string) (bool, error) {
	if accountID == "" || len(s.firstContentSLAAccounts)+len(s.firstContentSLAEmails) == 0 {
		return false, nil
	}
	if _, ok := s.firstContentSLAAccounts[accountID]; ok {
		return true, nil
	}
	if len(s.firstContentSLAEmails) == 0 {
		return false, nil
	}
	u, err := s.store.GetUserByAccountID(accountID)
	if errors.Is(err, store.ErrNotFound) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	if u == nil || u.Email == "" {
		return false, nil
	}
	_, ok := s.firstContentSLAEmails[strings.ToLower(strings.TrimSpace(u.Email))]
	return ok, nil
}

// Zero explicitly disables the SLA. Resolve enforcement before admission/media.
// A concrete native-media post-fetch recount may correct the token term once,
// still anchored to the original receive instant. Retries never restart it.
func (s *Owner) requestFirstContentDeadline(r *http.Request, publicModel, model string, tokens int) (time.Duration, error) {
	enabled, err := s.accountHasFirstContentSLA(access.ConsumerKeyFromContext(r.Context()))
	if err != nil || !enabled {
		return 0, err
	}
	if modelpolicy.HasFirstContentPolicy(publicModel) {
		model = publicModel
	}
	return s.FirstContentDeadline(model, tokens), nil
}

func firstContentAccountSelectors(accounts []string) (map[string]struct{}, map[string]struct{}) {
	out := make(map[string]struct{}, len(accounts))
	emails := make(map[string]struct{})
	for _, account := range accounts {
		account = strings.TrimSpace(account)
		if account == "" {
			continue
		}
		if strings.Contains(account, "@") {
			emails[strings.ToLower(account)] = struct{}{}
			continue
		}
		out[account] = struct{}{}
	}
	return out, emails
}

// Keep latency-oriented hedging for exempt requests, but never manufacture a
// deadline from this scheduling hint. An opted-in public-model override wins.
func (s *Owner) firstContentHedgeDelay(model string, tokens int, deadline time.Duration) time.Duration {
	if deadline <= 0 {
		deadline = s.FirstContentDeadline(model, tokens)
	}
	return time.Duration(float64(deadline) * speculativeTimerRatio)
}
