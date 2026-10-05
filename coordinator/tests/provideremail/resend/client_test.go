package resend_test

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/provideremail"
	"github.com/eigeninference/d-inference/coordinator/provideremail/resend"
)

type roundTripFunc func(*http.Request) (*http.Response, error)

func (f roundTripFunc) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }

func testClient(t *testing.T, handler http.HandlerFunc) *resend.Client {
	t.Helper()
	s := httptest.NewServer(handler)
	t.Cleanup(s.Close)
	target, err := url.Parse(s.URL)
	if err != nil {
		t.Fatal(err)
	}
	c, err := resend.New("test-secret", roundTripFunc(func(r *http.Request) (*http.Response, error) {
		if r.URL.Scheme != "https" || r.URL.Host != "api.resend.com" {
			t.Errorf("unexpected Resend endpoint: %s", r.URL)
		}
		request := r.Clone(r.Context())
		request.URL.Scheme, request.URL.Host = target.Scheme, target.Host
		return s.Client().Transport.RoundTrip(request)
	}))
	if err != nil {
		t.Fatal(err)
	}
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
	if _, err := c.CreateDraft(context.Background(), resend.Draft{SegmentID: "segment", Subject: "Update"}); err != nil {
		t.Fatal(err)
	}
}

func TestRenderedDraftUsesBroadcastReplyToArray(t *testing.T) {
	draft, err := provideremail.Render(provideremail.Campaign{
		ID: "announcement", Audience: "all", ActiveWithinDays: 30, OSMaxAgeDays: 7,
		Message: provideremail.Message{
			From: "providers@example.com", ReplyTo: "support@example.com", Subject: "Provider news",
			Severity: "recommended", Body: "Provider update instructions.", InstructionsURL: "https://example.com/update",
		},
	}, false)
	if err != nil {
		t.Fatal(err)
	}
	c := testClient(t, func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost || r.URL.Path != "/broadcasts" {
			t.Errorf("unexpected request: %s %s", r.Method, r.URL.Path)
		}
		var body struct {
			ReplyTo []string `json:"reply_to"`
		}
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
			t.Errorf("invalid broadcast reply_to: %v", err)
			http.Error(w, "reply_to must be an array", http.StatusBadRequest)
			return
		}
		if len(body.ReplyTo) != 1 || body.ReplyTo[0] != "support@example.com" {
			t.Errorf("unexpected reply_to: %v", body.ReplyTo)
		}
		fmt.Fprint(w, `{"id":"draft"}`)
	})
	if _, err := c.CreateDraft(context.Background(), draft); err != nil {
		t.Fatal(err)
	}
}

func TestMembersPreservesSegmentAcrossPages(t *testing.T) {
	const segment = "78261eea-8f8b-4381-83c6-79fa7120f1cf"
	calls := 0
	c := testClient(t, func(w http.ResponseWriter, r *http.Request) {
		calls++
		if r.Method != http.MethodGet || r.URL.Path != "/segments/"+segment+"/contacts" || r.URL.Query().Get("limit") != "100" {
			t.Errorf("unexpected membership request: %s %s", r.Method, r.URL)
		}
		if calls == 1 {
			fmt.Fprint(w, `{"data":[{"id":"first","email":"first@example.com","unsubscribed":true}],"has_more":true}`)
			return
		}
		if r.URL.Query().Get("after") != "first" {
			t.Error("missing membership pagination cursor")
		}
		fmt.Fprint(w, `{"data":[{"id":"last","email":"last@example.com"}],"has_more":false}`)
	})
	members, err := c.Members(context.Background(), segment)
	if err != nil || calls != 2 || len(members) != 2 {
		t.Fatalf("members=%+v calls=%d err=%v", members, calls, err)
	}
	if !members[0].Unsubscribed {
		t.Fatal("membership response lost subscription state")
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
			ReplyTo []string `json:"reply_to"`
		}
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
			t.Error(err)
		}
		if len(body.To) != 1 || body.To[0] != "tester@example.com" || !strings.HasPrefix(body.Subject, "[TEST]") {
			t.Errorf("%+v", body)
		}
		if len(body.ReplyTo) != 1 || body.ReplyTo[0] != "support@example.com" {
			t.Errorf("test email lost reply_to: %+v", body.ReplyTo)
		}
		fmt.Fprint(w, `{"id":"email"}`)
	})
	if _, err := c.SendTest(context.Background(), resend.Draft{Subject: "Update", ReplyTo: []string{"support@example.com"}}, "tester@example.com", "test-id"); err != nil {
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

func TestClientRefusesRedirects(t *testing.T) {
	calls := 0
	c := testClient(t, func(w http.ResponseWriter, r *http.Request) {
		calls++
		http.Redirect(w, r, "https://api.resend.com/redirected", http.StatusTemporaryRedirect)
	})
	_, err := c.Contacts(context.Background())
	var apiErr *resend.APIError
	if !errors.As(err, &apiErr) || apiErr.Status != http.StatusTemporaryRedirect || calls != 1 {
		t.Fatalf("redirect followed or hidden: calls=%d err=%v", calls, err)
	}
}

func TestInjectedTransportPreservesPacing(t *testing.T) {
	calls := 0
	c := testClient(t, func(w http.ResponseWriter, r *http.Request) {
		calls++
		fmt.Fprint(w, `{"data":[],"has_more":false}`)
	})
	if _, err := c.Contacts(context.Background()); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 50*time.Millisecond)
	defer cancel()
	if _, err := c.Contacts(ctx); !errors.Is(err, context.DeadlineExceeded) || calls != 1 {
		t.Fatalf("request bypassed pacing: calls=%d err=%v", calls, err)
	}
}
