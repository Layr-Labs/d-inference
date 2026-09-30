package api

import (
	"fmt"
	"testing"
)

func TestCachePlanningComposedPrivacyAndAuthenticatedScope(t *testing.T) {
	f := newPrivacyPlanningFixture(t, 1)
	seenNonces := make(map[string]bool)
	for _, endpoint := range []string{"/v1/chat/completions", "/v1/responses", "/v1/completions", "/v1/messages"} {
		for _, stream := range []bool{false, true} {
			t.Run(fmt.Sprintf("%s/stream=%t", endpoint, stream), func(t *testing.T) {
				before := f.mark(t, privacyPlanningAccountA)
				done, cancel := f.start(t, privacyPlanningAccountA, endpoint,
					privacyPlanningBody(t, f.planning.model, endpoint, stream, privacyPlanningAccountB))
				defer cancel()
				records := f.assertSuccess(t, before, privacyPlanningAccountA, endpoint, stream, f.finish(t, done), 1, true)
				nonce := records[0].frame.CacheReceiptNonce
				if seenNonces[nonce] {
					t.Fatal("distinct requests reused a receipt nonce")
				}
				seenNonces[nonce] = true
			})
		}
	}
	t.Run("authenticated_accounts_not_caller_user", func(t *testing.T) {
		var scopes []string
		for _, test := range []struct{ account, caller string }{
			{privacyPlanningAccountA, privacyPlanningAccountA},
			{privacyPlanningAccountA, privacyPlanningAccountB},
			{privacyPlanningAccountB, privacyPlanningAccountA},
		} {
			before := f.mark(t, test.account)
			done, cancel := f.start(t, test.account, "/v1/chat/completions",
				privacyPlanningBody(t, f.planning.model, "/v1/chat/completions", false, test.caller))
			result := f.finish(t, done)
			cancel()
			records := f.assertSuccess(t, before, test.account, "/v1/chat/completions", false, result, 1, true)
			scopes = append(scopes, records[0].frame.CacheScope)
		}
		if scopes[0] != scopes[1] || scopes[1] == scopes[2] {
			t.Fatal("cache scope followed caller user or failed to isolate authenticated accounts")
		}
	})
}
