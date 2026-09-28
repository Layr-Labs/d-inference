package api

import (
	"fmt"
	"log/slog"
	"net/http"
	"strings"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/jackc/pgx/v5/pgconn"
)

type modelPromotionFailureStore struct {
	store.Store
	err error
}

func (s *modelPromotionFailureStore) PromoteModelVersion(string, string) error {
	return s.err
}

func TestModelRevisionPromotionClassifiesMissingModelAndDatabaseErrors(t *testing.T) {
	t.Setenv("MODEL_REGISTRY_PUBLISHING_KEY", "publish-secret")
	for _, tc := range []struct {
		name string
		err  error
		want int
	}{
		{name: "memory missing model", want: http.StatusNotFound},
		{name: "postgres missing parent", err: fmt.Errorf("model %q: %w", "missing-model", store.ErrNotFound), want: http.StatusNotFound},
		{name: "postgres row lock failure", err: &pgconn.PgError{Code: "25006", Message: "cannot execute SELECT FOR UPDATE in a read-only transaction"}, want: http.StatusInternalServerError},
	} {
		t.Run(tc.name, func(t *testing.T) {
			var st store.Store = store.NewMemory(store.Config{})
			if tc.err != nil {
				st = &modelPromotionFailureStore{Store: st, err: tc.err}
			}
			srv := NewServer(registry.New(slog.Default()), st, ServerConfig{}, slog.Default())
			t.Cleanup(srv.Close)
			response := modelRevisionActionRequest(t, srv, "missing-model", "promote", map[string]any{"version": "v1"})
			if response.Code != tc.want {
				t.Fatalf("promotion returned %d, want %d: %s", response.Code, tc.want, response.Body.String())
			}
			if tc.want == http.StatusInternalServerError && strings.Contains(response.Body.String(), "SELECT") {
				t.Fatalf("database details exposed in API error: %s", response.Body.String())
			}
		})
	}
}
