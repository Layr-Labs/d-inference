package accounts_test

import (
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/api/access"
	"github.com/eigeninference/d-inference/coordinator/api/accounts"
	"github.com/eigeninference/d-inference/coordinator/store"
)

const interestExportAdminKey = "synthetic-interest-export-admin"

type interestExportCall struct {
	after string
	limit int
}

type recordingInterestExportStore struct {
	accounts.Store // Unexpected persistence calls fail instead of reaching a backend.
	calls          []interestExportCall
	rows           []store.SmallModelsInterestContact
}

func (s *recordingInterestExportStore) ListSmallModelsInterest(_ context.Context, after string, limit int) ([]store.SmallModelsInterestContact, error) {
	s.calls = append(s.calls, interestExportCall{after: after, limit: limit})
	return s.rows, nil
}

func interestExportOwner(st *recordingInterestExportStore) *accounts.Owner {
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	authorizer := access.New(nil, logger, 1024, access.Hooks{})
	authorizer.SetAdminKey(interestExportAdminKey)
	return accounts.New(accounts.Dependencies{Store: st, Access: authorizer, Logger: logger})
}

func TestSmallModelsInterestExportCursorValidation(t *testing.T) {
	for _, tc := range []struct {
		name   string
		cursor string
		valid  bool
	}{
		{name: "empty", valid: true},
		{name: "account_id", cursor: "account-a", valid: true},
		{name: "opaque_id", cursor: "account:+/=% value", valid: true},
		{name: "unicode", cursor: "account-é", valid: true},
		{name: "256_ascii_bytes", cursor: strings.Repeat("a", 256), valid: true},
		{name: "256_utf8_bytes", cursor: strings.Repeat("é", 128), valid: true},
		{name: "257_ascii_bytes", cursor: strings.Repeat("a", 257)},
		{name: "258_utf8_bytes", cursor: strings.Repeat("é", 129)},
		{name: "nul", cursor: "\x00"},
		{name: "embedded_nul", cursor: "account\x00tail"},
		{name: "invalid_utf8", cursor: "account\xff"},
		{name: "truncated_utf8", cursor: "\xc3"},
		{name: "utf8_surrogate", cursor: "\xed\xa0\x80"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			st := &recordingInterestExportStore{}
			r := httptest.NewRequest(http.MethodGet, "/v1/admin/interest/small-models?after="+url.QueryEscape(tc.cursor), nil)
			r.Header.Set("Authorization", "Bearer "+interestExportAdminKey)
			w := httptest.NewRecorder()
			interestExportOwner(st).HandleAdminSmallModelsInterest(w, r)
			if !tc.valid {
				if w.Code != http.StatusBadRequest {
					t.Errorf("status=%d, want 400 for cursor bytes %x", w.Code, []byte(tc.cursor))
				}
				if len(st.calls) != 0 {
					t.Errorf("store received %d call(s), want none for invalid cursor", len(st.calls))
				}
				var body struct {
					Error struct{ Type, Message string }
				}
				if err := json.Unmarshal(w.Body.Bytes(), &body); err != nil {
					t.Fatal(err)
				}
				if body.Error.Type != "invalid_request_error" || body.Error.Message != "invalid cursor" {
					t.Errorf("unexpected cursor error: %s", w.Body)
				}
				return
			}
			if w.Code != http.StatusOK || w.Header().Get("Cache-Control") != "private, no-store" {
				t.Fatalf("status=%d, headers=%v", w.Code, w.Header())
			}
			if len(st.calls) != 1 || st.calls[0] != (interestExportCall{after: tc.cursor, limit: 100}) {
				t.Fatalf("store calls=%+v, want unchanged cursor and default limit", st.calls)
			}
		})
	}
}

func TestSmallModelsInterestExportPagination(t *testing.T) {
	for _, tc := range []struct {
		query string
		limit int
		next  string
	}{
		{query: "", limit: 100},
		{query: "?after=account-a&limit=1", limit: 1, next: "account-b"},
		{query: "?after=account-a&limit=2", limit: 2},
	} {
		t.Run(tc.query, func(t *testing.T) {
			st := &recordingInterestExportStore{rows: []store.SmallModelsInterestContact{{
				SmallModelsInterest: store.SmallModelsInterest{AccountID: "account-b"}, Email: "synthetic@example.test",
			}}}
			r := httptest.NewRequest(http.MethodGet, "/v1/admin/interest/small-models"+tc.query, nil)
			r.Header.Set("Authorization", "Bearer "+interestExportAdminKey)
			w := httptest.NewRecorder()
			interestExportOwner(st).HandleAdminSmallModelsInterest(w, r)
			if w.Code != http.StatusOK {
				t.Fatalf("status=%d: %s", w.Code, w.Body)
			}
			if len(st.calls) != 1 || st.calls[0] != (interestExportCall{after: r.URL.Query().Get("after"), limit: tc.limit}) {
				t.Fatalf("store calls=%+v", st.calls)
			}
			var page struct {
				Data []store.SmallModelsInterestContact `json:"data"`
				Next string                             `json:"next_cursor"`
			}
			if err := json.Unmarshal(w.Body.Bytes(), &page); err != nil {
				t.Fatal(err)
			}
			if len(page.Data) != 1 || page.Data[0] != st.rows[0] || page.Next != tc.next {
				t.Fatalf("unexpected page: %s", w.Body)
			}
			if tc.next == "" && strings.Contains(w.Body.String(), "next_cursor") {
				t.Fatalf("terminal page contains a next cursor: %s", w.Body)
			}
		})
	}
}

func TestSmallModelsInterestExportAuthorizationPrecedesCursorValidation(t *testing.T) {
	for _, cursor := range []string{"account-a", "\x00"} {
		for _, credential := range []string{"missing", "wrong", "inference_key"} {
			t.Run(credential+"/"+url.QueryEscape(cursor), func(t *testing.T) {
				st := &recordingInterestExportStore{}
				r := httptest.NewRequest(http.MethodGet, "/v1/admin/interest/small-models?after="+url.QueryEscape(cursor), nil)
				if credential == "wrong" {
					r.Header.Set("Authorization", "Bearer incorrect-synthetic-key")
				} else if credential == "inference_key" {
					r.Header.Set("Authorization", "Bearer "+interestExportAdminKey)
					r = r.WithContext(access.WithAPIKey(r.Context(), &store.APIKey{}))
				}
				w := httptest.NewRecorder()
				interestExportOwner(st).HandleAdminSmallModelsInterest(w, r)
				if w.Code != http.StatusForbidden || len(st.calls) != 0 {
					t.Fatalf("status=%d, store calls=%d; want 403 without store access", w.Code, len(st.calls))
				}
			})
		}
	}
}
