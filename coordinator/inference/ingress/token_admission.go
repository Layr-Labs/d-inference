package ingress

import (
	"github.com/eigeninference/d-inference/coordinator/api/requestcontext"
	"hash/fnv"
	"net/http"
	"sync"
	"time"

	"github.com/eigeninference/d-inference/coordinator/ratelimit"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

type keyTokenLimits struct {
	id                      string
	inputRPS, outputRPS     float64
	inputBurst, outputBurst int
}

func (s *Controller) keyTokenLimits(r *http.Request) *keyTokenLimits {
	if s.deps.KeyTokens() == nil {
		return nil
	}
	key := requestcontext.APIKey(r.Context())
	if key == nil || key.ID == "" {
		return nil
	}
	limits := &keyTokenLimits{id: key.ID}
	if key.ITPMLimit != nil && *key.ITPMLimit > 0 {
		limits.inputRPS, limits.inputBurst = float64(*key.ITPMLimit)/60, int(*key.ITPMLimit)
	}
	if key.OTPMLimit != nil && *key.OTPMLimit > 0 {
		limits.outputRPS, limits.outputBurst = float64(*key.OTPMLimit)/60, int(*key.OTPMLimit)
	}
	if limits.inputRPS <= 0 && limits.outputRPS <= 0 {
		return nil
	}
	return limits
}

// Every key belongs to one account. Serialize that account's whole admission
// transaction, including reconciliation debt, across both key and tier buckets.
// The fixed shard table bounds memory; HTTP writes happen after unlocking.
func (s *Controller) tokenAdmissionLock(accountID string) *sync.Mutex {
	h := fnv.New32a()
	_, _ = h.Write([]byte(accountID))
	return &s.tokenAdmissionMu[h.Sum32()%uint32(len(s.tokenAdmissionMu))]
}

func (s *Controller) admitTokenBuckets(accountID string, account *ratelimit.TokenLimiter, key *keyTokenLimits, input, output int) (string, string, time.Duration) {
	lock := s.tokenAdmissionLock(accountID)
	lock.Lock()
	defer lock.Unlock()
	if key != nil {
		if ok, dimension, retry := s.deps.KeyTokens().Peek(key.id, input, output, key.inputRPS, key.inputBurst, key.outputRPS, key.outputBurst); !ok {
			return "key", dimension, retry
		}
	}
	if account != nil {
		if ok, dimension, retry := account.Peek(accountID, input, output); !ok {
			return "account", dimension, retry
		}
	}
	if key != nil {
		s.deps.KeyTokens().Commit(key.id, input, output, key.inputRPS, key.inputBurst, key.outputRPS, key.outputBurst)
	}
	if account != nil {
		account.Commit(accountID, input, output)
	}
	return "", "", 0
}

func (s *Controller) debitAdmissionOutput(pr *registry.PendingRequest, delta int) {
	lock := s.tokenAdmissionLock(pr.ConsumerKey)
	lock.Lock()
	defer lock.Unlock()
	admission := pr.TokenAdmission
	if admission.AccountOutputLimited {
		var tl *ratelimit.TokenLimiter
		switch admission.AccountTier {
		case "service":
			tl = s.deps.ServiceTokens()
		default:
			tl = s.deps.ConsumerTokens()
		}
		if tl != nil {
			tl.DebitOutput(pr.ConsumerKey, delta)
		}
	}
	if admission.KeyOutputLimited && s.deps.KeyTokens() != nil {
		s.deps.KeyTokens().DebitOutput(pr.KeyID, delta, admission.KeyOutputRPS, admission.KeyOutputBurst)
	}
}
