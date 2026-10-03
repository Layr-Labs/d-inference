package reporting_test

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api"
	"github.com/eigeninference/d-inference/coordinator/api/tests/internal/testkit"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func TestModelDemandPublicEndpoint(t *testing.T) {
	s := testkit.New(t, api.ServerConfig{}).Server
	for _, window := range []string{"24h", "7d", "30d", ""} {
		w := httptest.NewRecorder()
		s.Handler().ServeHTTP(w, httptest.NewRequest(http.MethodGet, "/v1/network/model-demand?window="+window, nil))
		if w.Code != 200 {
			t.Fatalf("%s: %d %s", window, w.Code, w.Body.String())
		}
		var v struct {
			Coverage       string `json:"coverage"`
			StartAt, EndAt time.Time
			Models         []store.ModelDemandCounts
		}
		var raw map[string]json.RawMessage
		if err := json.Unmarshal(w.Body.Bytes(), &raw); err != nil {
			t.Fatal(err)
		}
		_ = json.Unmarshal(raw["end_at"], &v.EndAt)
		_ = json.Unmarshal(raw["start_at"], &v.StartAt)
		if !v.StartAt.Before(v.EndAt) || time.Since(v.EndAt) < time.Hour || v.EndAt.Minute() != 0 {
			t.Fatalf("invalid boundary %+v", v)
		}
		if strings.Contains(w.Body.String(), "consumer_hash") || strings.Contains(w.Body.String(), "raw_reason") {
			t.Fatal("private evidence exposed")
		}
	}
	w := httptest.NewRecorder()
	s.Handler().ServeHTTP(w, httptest.NewRequest("GET", "/v1/network/model-demand?window=all", nil))
	if w.Code != 400 {
		t.Fatalf("unbounded window: %d", w.Code)
	}
}
