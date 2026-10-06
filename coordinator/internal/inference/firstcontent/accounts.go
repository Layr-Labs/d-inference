package firstcontent

import (
	"errors"
	"net/http"
	"strings"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api/access"
	"github.com/eigeninference/d-inference/coordinator/modelpolicy"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// AccountPolicy resolves operator-selected accounts from stored identity, never
// from caller headers. Bind runs once during owner construction, before serving.
type AccountPolicy struct {
	store    store.Store
	accounts map[string]struct{}
	emails   map[string]struct{}
	deadline func(string, int) time.Duration
}

func (p *AccountPolicy) Bind(st store.Store, selectors []string, deadline func(string, int) time.Duration) {
	p.store, p.deadline = st, deadline
	p.accounts, p.emails = make(map[string]struct{}, len(selectors)), make(map[string]struct{})
	for _, selector := range selectors {
		selector = strings.TrimSpace(selector)
		if selector == "" {
			continue
		}
		if strings.Contains(selector, "@") {
			p.emails[strings.ToLower(selector)] = struct{}{}
			continue
		}
		p.accounts[selector] = struct{}{}
	}
}

func (p *AccountPolicy) enabled(account string) (bool, error) {
	if p == nil || account == "" || len(p.accounts)+len(p.emails) == 0 {
		return false, nil
	}
	if _, ok := p.accounts[account]; ok {
		return true, nil
	}
	if len(p.emails) == 0 {
		return false, nil
	}
	u, err := p.store.GetUserByAccountID(account)
	if errors.Is(err, store.ErrNotFound) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	if u == nil || u.Email == "" {
		return false, nil
	}
	_, ok := p.emails[strings.ToLower(strings.TrimSpace(u.Email))]
	return ok, nil
}

func (p *AccountPolicy) Deadline(r *http.Request, publicModel, model string, tokens int) (time.Duration, error) {
	enabled, err := p.enabled(access.ConsumerKeyFromContext(r.Context()))
	if err != nil || !enabled {
		return 0, err
	}
	if modelpolicy.HasFirstContentPolicy(publicModel) {
		model = publicModel
	}
	return p.deadline(model, tokens), nil
}

// HedgeDelay remains an advisory hint for exempt requests, not an SLA budget.
func (p *AccountPolicy) HedgeDelay(model string, tokens int, deadline time.Duration) time.Duration {
	if deadline <= 0 {
		deadline = p.deadline(model, tokens)
	}
	return time.Duration(float64(deadline) * 0.5)
}
