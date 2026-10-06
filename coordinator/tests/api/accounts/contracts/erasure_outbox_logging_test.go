package accounts_test

import (
	"encoding/json"
	"log/slog"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
)

type outboxLogLines chan string

func (lines outboxLogLines) Write(p []byte) (int, error) {
	lines <- string(p)
	return len(p), nil
}

func TestErasureOutboxManualActionLogExcludesUpstreamError(t *testing.T) {
	for _, status := range []int{http.StatusBadRequest, http.StatusInternalServerError} {
		t.Run(http.StatusText(status), func(t *testing.T) {
			lines := make(outboxLogLines, 64)
			fx := newOutboxFixtureWithLogger(t, false, slog.New(slog.NewJSONHandler(lines, nil)))
			const stripeID = "acct_privateLogging"
			const email = "private@example.com"
			const message = "Refused account " + stripeID + " belonging to " + email
			account := fx.scrub(t, outboxSeed{stripeAccount: stripeID})
			fx.stripe.on(http.MethodDelete, "/v1/accounts/"+stripeID, status,
				`{"error":{"code":"invalid_request","message":"`+message+`"}}`)
			if status == http.StatusInternalServerError {
				fx.setRow(t, fx.row(t, account, store.ErasureTargetStripeAccount), func(r *store.ErasureOutboxResult) {
					r.Attempts = outboxMaxAttempts - 1
				})
			}
			fx.pass(t, account)
			row := fx.row(t, account, store.ErasureTargetStripeAccount)
			wantManual(t, row, message)
			contact := fx.row(t, account, store.ErasureTargetResendContact)
			pendingLogs := map[string]store.ErasureOutboxItem{row.ID: row, contact.ID: contact}
			if fx.stripe.count("DELETE /v1/accounts/"+stripeID) != 1 {
				t.Fatal("expected one local Stripe HTTP request")
			}
			timer := time.NewTimer(5 * time.Second)
			defer timer.Stop()
			for len(pendingLogs) > 0 {
				select {
				case line := <-lines:
					if strings.Contains(line, stripeID) || strings.Contains(line, email) || strings.Contains(line, message) || strings.Contains(line, contact.ExternalID) {
						t.Fatalf("upstream error leaked into operational log: %s", line)
					}
					var entry map[string]any
					if err := json.Unmarshal([]byte(line), &entry); err != nil {
						t.Fatal(err)
					}
					if entry["msg"] != "erasure outbox: manual action required" {
						continue
					}
					id, _ := entry["outbox_id"].(string)
					loggedRow, ok := pendingLogs[id]
					if !ok {
						continue
					}
					for key, want := range map[string]any{
						"outbox_id": loggedRow.ID, "request_id": loggedRow.RequestID, "target": string(loggedRow.Target),
						"state": string(loggedRow.State), "attempts": float64(loggedRow.Attempts),
					} {
						if entry[key] != want {
							t.Errorf("log %s = %v, want %v", key, entry[key], want)
						}
					}
					if _, ok := entry["error"]; ok {
						t.Error("manual-action log must not include upstream error text")
					}
					delete(pendingLogs, id)
				case <-timer.C:
					t.Fatal("manual-action log was not emitted")
				}
			}
		})
	}
}
