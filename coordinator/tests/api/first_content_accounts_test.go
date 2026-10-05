package api_test

import (
	"testing"

	production "github.com/eigeninference/d-inference/coordinator/api"
)

func TestFirstContentSLAAccountsEnvironment(t *testing.T) {
	t.Setenv("EIGENINFERENCE_FIRST_CONTENT_SLA_ACCOUNTS", " partner@example.invalid , account-2 ")
	cfg := production.ReadServerConfig()
	if len(cfg.FirstContentSLAAccounts) != 2 || cfg.FirstContentSLAAccounts[0] != "partner@example.invalid" || cfg.FirstContentSLAAccounts[1] != "account-2" {
		t.Fatal(cfg.FirstContentSLAAccounts)
	}
}
