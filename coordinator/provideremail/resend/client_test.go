package resend

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func testClient(t *testing.T, handler http.HandlerFunc) *Client {
	t.Helper()
	s := httptest.NewServer(handler)
	t.Cleanup(s.Close)
	c, err := New("test-secret")
	if err != nil {
		t.Fatal(err)
	}
	c.baseURL = s.URL
	c.http = s.Client()
	c.interval = 0
	return c
}

func TestPaginationUsesCursorAndFailsClosed(t *testing.T) {
	calls := 0
	c := testClient(t, func(w http.ResponseWriter, r *http.Request) {
		calls++
		if r.Header.Get("Authorization") != "Bearer test-secret" || r.URL.Query().Get("limit") != "100" {
			t.Error("missing auth or limit")
		}
		if calls == 1 {
			fmt.Fprint(w, `{"data":[{"id":"first","email":"first@example.com"}],"has_more":true}`)
			return
		}
		if r.URL.Query().Get("after") != "first" {
			t.Error("missing pagination cursor")
		}
		fmt.Fprint(w, `{"data":[{"id":"last","email":"last@example.com"}],"has_more":false}`)
	})
	contacts, err := c.Contacts(context.Background())
	if err != nil || len(contacts) != 2 || calls != 2 {
		t.Fatalf("%+v %v", contacts, err)
	}
	for _, body := range []string{`{"data":[]}`, `{"has_more":false}`, `{"data":[],"has_more":true}`, `{"data":[{"id":"same"}],"has_more":true}`} {
		bad := testClient(t, func(w http.ResponseWriter, r *http.Request) { fmt.Fprint(w, body) })
		if _, err := bad.Contacts(context.Background()); err == nil {
			t.Fatalf("accepted %s", body)
		}
	}
}

func TestWritesDoNotResetPreferencesOrSendDrafts(t *testing.T) {
	c := testClient(t, func(w http.ResponseWriter, r *http.Request) {
		var body map[string]any
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
			t.Error(err)
		}
		for _, key := range []string{"unsubscribed", "topics", "send", "scheduled_at"} {
			if _, ok := body[key]; ok {
				t.Errorf("unexpected field %s", key)
			}
		}
		fmt.Fprint(w, `{"id":"created"}`)
	})
	if _, err := c.CreateContact(context.Background(), "owner@example.com"); err != nil {
		t.Fatal(err)
	}
	if _, err := c.CreateDraft(context.Background(), Draft{SegmentID: "segment", Subject: "Update"}); err != nil {
		t.Fatal(err)
	}
}

func TestRedactsErrorsAndDoesNotRetryAmbiguousCreates(t *testing.T) {
	calls := 0
	c := testClient(t, func(w http.ResponseWriter, r *http.Request) {
		calls++
		w.WriteHeader(500)
		fmt.Fprint(w, "secret-body owner@example.com test-secret")
	})
	_, err := c.CreateContact(context.Background(), "owner@example.com")
	if err == nil || calls != 1 || strings.Contains(err.Error(), "secret") || strings.Contains(err.Error(), "@") {
		t.Fatalf("calls=%d err=%v", calls, err)
	}
}

func TestTestSendHasOneRecipientAndIdempotency(t *testing.T) {
	c := testClient(t, func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/emails" || r.Header.Get("Idempotency-Key") != "test-id" {
			t.Error("wrong test request")
		}
		var body struct {
			To      []string `json:"to"`
			Subject string   `json:"subject"`
		}
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
			t.Error(err)
		}
		if len(body.To) != 1 || body.To[0] != "tester@example.com" || !strings.HasPrefix(body.Subject, "[TEST]") {
			t.Errorf("%+v", body)
		}
		fmt.Fprint(w, `{"id":"email"}`)
	})
	if _, err := c.SendTest(context.Background(), Draft{Subject: "Update"}, "tester@example.com", "test-id"); err != nil {
		t.Fatal(err)
	}
}

func TestCancellationStopsRateLimitWait(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	calls := 0
	c := testClient(t, func(w http.ResponseWriter, r *http.Request) { calls++; cancel(); w.WriteHeader(429) })
	if _, err := c.Segments(ctx); err == nil || calls != 1 {
		t.Fatalf("calls=%d err=%v", calls, err)
	}
}
