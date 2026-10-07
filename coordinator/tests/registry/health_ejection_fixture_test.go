package registry_test

import (
	"fmt"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/identitygate"
	production "github.com/eigeninference/d-inference/coordinator/registry"
)

const (
	healthEjectionConsecTrip         = 8
	healthEjectionCapacityConsecTrip = 10
	healthEjectionBaseCooldown       = 60 * time.Second
	healthEjectionWindow             = 10 * time.Minute
)

func healthEjectionOpenAt(gates *identitygate.Directory, sid string, now time.Time) bool {
	return gates.ViewIdentity(sid).EjectedAt(now.UnixNano())
}

func stableHealthIdentity(t *testing.T, input *production.Provider) string {
	t.Helper()
	reg := production.New(testLogger())
	p := reg.Register("identity", nil, testRegisterMessage())
	p.Mu().Lock()
	p.AccountID = input.AccountID
	p.Mu().Unlock()
	p.SetAttestationResult(input.AttestationResult)
	return reg.GetProviderStableIdentity(p.ID)
}

func healthReserveOne(reg *production.Registry, model string, reqMax int) *production.Provider {
	pr := &production.PendingRequest{
		RequestID:          fmt.Sprintf("scenario-req-%d", time.Now().UnixNano()),
		Model:              model,
		RequestedMaxTokens: reqMax,
	}
	return reg.ReserveProvider(model, pr)
}
