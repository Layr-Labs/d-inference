package observation_test

import (
	"context"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api/access"
	"github.com/eigeninference/d-inference/coordinator/api/observation"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
)

func TestPublicModelDemandScopePersistsThroughObservation(t *testing.T) {
	for _, mode := range []string{"public", "self", "prefer", "restricted", "anonymous", "admin"} {
		t.Run(mode, func(t *testing.T) {
			st := memory.NewMemory(store.Config{})
			o := observation.New(observation.Dependencies{Store: st, Logger: quietLogger()})
			t.Cleanup(o.Close)
			ctx := context.Background()
			if mode != "anonymous" {
				consumer := "account-secret"
				if mode == "admin" {
					consumer = "admin"
				}
				ctx = access.WithConsumer(ctx, consumer)
			}
			r := httptest.NewRequest(http.MethodPost, "/v1/messages", nil).WithContext(ctx)
			o.ObserveRequestOutcome(func(w http.ResponseWriter, r *http.Request) {
				var serials []string
				if mode == "restricted" {
					serials = []string{"machine"}
				}
				observation.MarkPublicModelDemand(r, mode == "self", mode == "prefer", serials, "public-alias", "resolved-build")
				w.WriteHeader(http.StatusBadRequest)
			})(httptest.NewRecorder(), r)
			o.Close()
			rows, err := st.RequestOutcomes(context.Background(), time.Time{}, time.Now(), 10)
			if err != nil || len(rows) != 1 {
				t.Fatalf("outcome rows=%+v err=%v", rows, err)
			}
			d := rows[0].PublicDemand
			if mode == "public" {
				if d == nil || d.Model != "public-alias" || d.ConsumerHash != store.HashKey("account-secret") {
					t.Fatalf("scope %+v", d)
				}
			} else if d != nil {
				t.Fatal("private request included")
			}
		})
	}
}
