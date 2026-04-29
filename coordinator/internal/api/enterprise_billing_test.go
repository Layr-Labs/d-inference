package api

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/coordinator/internal/protocol"
	"github.com/eigeninference/coordinator/internal/registry"
	"github.com/eigeninference/coordinator/internal/store"
)

func enterpriseAdminRequest(method, path, body string) *http.Request {
	req := httptest.NewRequest(method, path, strings.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	return withPrivyUser(req, &store.User{
		AccountID:   "acct-admin",
		PrivyUserID: "did:privy:admin",
		Email:       "admin@example.com",
	})
}

func TestAdminEnterpriseAccountAllowsEditableTermsDays(t *testing.T) {
	srv, st := testBillingServer(t)
	srv.SetAdminEmails([]string{"admin@example.com"})

	body := `{"account_id":"acct-ent","billing_email":"billing@example.com","cadence":"weekly","terms_days":0,"credit_limit_micro_usd":5000000}`
	req := enterpriseAdminRequest(http.MethodPut, "/v1/admin/enterprise/account", body)
	w := httptest.NewRecorder()
	srv.handleAdminUpsertEnterpriseAccount(w, req)
	if w.Code != http.StatusOK {
		t.Fatalf("status = %d: %s", w.Code, w.Body.String())
	}
	account, err := st.GetEnterpriseAccount("acct-ent")
	if err != nil {
		t.Fatalf("GetEnterpriseAccount: %v", err)
	}
	if account.TermsDays != 0 {
		t.Fatalf("terms_days = %d, want 0", account.TermsDays)
	}

	updateBody := `{"account_id":"acct-ent","billing_email":"new-billing@example.com","credit_limit_micro_usd":7000000}`
	req = enterpriseAdminRequest(http.MethodPut, "/v1/admin/enterprise/account", updateBody)
	w = httptest.NewRecorder()
	srv.handleAdminUpsertEnterpriseAccount(w, req)
	if w.Code != http.StatusOK {
		t.Fatalf("update status = %d: %s", w.Code, w.Body.String())
	}
	account, err = st.GetEnterpriseAccount("acct-ent")
	if err != nil {
		t.Fatalf("GetEnterpriseAccount after update: %v", err)
	}
	if account.TermsDays != 0 {
		t.Fatalf("terms_days after omitted update = %d, want preserved 0", account.TermsDays)
	}
	if account.Cadence != store.EnterpriseCadenceWeekly {
		t.Fatalf("cadence after omitted update = %q, want preserved weekly", account.Cadence)
	}
}

func TestAdminEnterpriseAccountAllowsAdminKey(t *testing.T) {
	srv, st := testBillingServer(t)
	srv.SetAdminKey("admin-secret")

	body := `{"account_id":"acct-ent-key","billing_email":"billing@example.com","cadence":"monthly","terms_days":15,"credit_limit_micro_usd":5000000}`
	req := httptest.NewRequest(http.MethodPut, "/v1/admin/enterprise/account", strings.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer admin-secret")
	w := httptest.NewRecorder()
	srv.handleAdminUpsertEnterpriseAccount(w, req)
	if w.Code != http.StatusOK {
		t.Fatalf("status = %d: %s", w.Code, w.Body.String())
	}
	if _, err := st.GetEnterpriseAccount("acct-ent-key"); err != nil {
		t.Fatalf("GetEnterpriseAccount: %v", err)
	}
}

func TestAdminRunEnterpriseInvoicesCreatesStripeInvoice(t *testing.T) {
	var invoiceForm url.Values
	var customerIDKey string
	fakeStripe := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		form, _ := url.ParseQuery(string(body))
		w.Header().Set("Content-Type", "application/json")
		switch r.URL.Path {
		case "/v1/customers":
			customerIDKey = r.Header.Get("Idempotency-Key")
			_, _ = w.Write([]byte(`{"id":"cus_ent","email":"billing@example.com"}`))
		case "/v1/invoiceitems":
			_, _ = w.Write([]byte(`{"id":"ii_ent"}`))
		case "/v1/invoices":
			invoiceForm = form
			_, _ = w.Write([]byte(`{"id":"in_ent","status":"draft","amount_due":250}`))
		case "/v1/invoices/in_ent/finalize":
			_, _ = w.Write([]byte(`{"id":"in_ent","status":"open","amount_due":250,"due_date":1893456000}`))
		case "/v1/invoices/in_ent/send":
			_, _ = w.Write([]byte(`{"id":"in_ent","status":"open","hosted_invoice_url":"https://invoice.test/in_ent","invoice_pdf":"https://invoice.test/in_ent.pdf","amount_due":250}`))
		default:
			http.Error(w, "unexpected path", http.StatusNotFound)
		}
	}))
	defer fakeStripe.Close()

	srv, st := stripePayoutsTestServer(t, false, fakeStripe)
	srv.SetAdminEmails([]string{"admin@example.com"})
	start := time.Now().Add(-8 * 24 * time.Hour).Truncate(time.Second)
	if err := st.UpsertEnterpriseAccount(&store.EnterpriseAccount{
		AccountID:           "acct-ent",
		Status:              store.EnterpriseStatusActive,
		BillingEmail:        "billing@example.com",
		Cadence:             store.EnterpriseCadenceWeekly,
		TermsDays:           15,
		CreditLimitMicroUSD: 10_000_000,
		AccruedMicroUSD:     2_500_000,
		CurrentPeriodStart:  start,
		NextInvoiceAt:       start,
	}); err != nil {
		t.Fatalf("UpsertEnterpriseAccount: %v", err)
	}

	req := enterpriseAdminRequest(http.MethodPost, "/v1/admin/enterprise/invoices/run", `{"account_id":"acct-ent"}`)
	w := httptest.NewRecorder()
	srv.handleAdminRunEnterpriseInvoices(w, req)
	if w.Code != http.StatusOK {
		t.Fatalf("status = %d: %s", w.Code, w.Body.String())
	}
	if got := invoiceForm.Get("collection_method"); got != "send_invoice" {
		t.Fatalf("collection_method = %q, want send_invoice", got)
	}
	if got := invoiceForm.Get("days_until_due"); got != "15" {
		t.Fatalf("days_until_due = %q, want 15", got)
	}
	if got := invoiceForm.Get("pending_invoice_items_behavior"); got != "include" {
		t.Fatalf("pending_invoice_items_behavior = %q, want include", got)
	}
	if customerIDKey == "" {
		t.Fatal("missing customer idempotency key")
	}
	invoices, err := st.ListEnterpriseInvoices("acct-ent", 10)
	if err != nil {
		t.Fatalf("ListEnterpriseInvoices: %v", err)
	}
	if len(invoices) != 1 {
		t.Fatalf("invoice count = %d, want 1", len(invoices))
	}
	if invoices[0].StripeInvoiceID != "in_ent" || invoices[0].AmountCents != 250 {
		t.Fatalf("invoice = %+v", invoices[0])
	}
	account, _ := st.GetEnterpriseAccount("acct-ent")
	if account.OpenInvoiceMicroUSD != 2_500_000 || account.AccruedMicroUSD != 0 {
		t.Fatalf("open/accrued = %d/%d, want 2500000/0", account.OpenInvoiceMicroUSD, account.AccruedMicroUSD)
	}
}

func TestAdminRunEnterpriseInvoicesSkipsBelowCentWithoutMutatingAccrual(t *testing.T) {
	fakeStripe := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		t.Fatalf("Stripe should not be called for sub-cent Enterprise invoice run: %s", r.URL.Path)
	}))
	defer fakeStripe.Close()

	srv, st := stripePayoutsTestServer(t, false, fakeStripe)
	srv.SetAdminEmails([]string{"admin@example.com"})
	start := time.Now().Add(-8 * 24 * time.Hour).Truncate(time.Second)
	if err := st.UpsertEnterpriseAccount(&store.EnterpriseAccount{
		AccountID:           "acct-subcent",
		Status:              store.EnterpriseStatusActive,
		BillingEmail:        "billing@example.com",
		Cadence:             store.EnterpriseCadenceWeekly,
		TermsDays:           15,
		CreditLimitMicroUSD: 10_000_000,
		AccruedMicroUSD:     9_999,
		CurrentPeriodStart:  start,
		NextInvoiceAt:       start,
	}); err != nil {
		t.Fatalf("UpsertEnterpriseAccount: %v", err)
	}

	req := enterpriseAdminRequest(http.MethodPost, "/v1/admin/enterprise/invoices/run", `{"account_id":"acct-subcent"}`)
	w := httptest.NewRecorder()
	srv.handleAdminRunEnterpriseInvoices(w, req)
	if w.Code != http.StatusOK {
		t.Fatalf("status = %d: %s", w.Code, w.Body.String())
	}
	account, _ := st.GetEnterpriseAccount("acct-subcent")
	if account.AccruedMicroUSD != 9_999 || account.RoundingCarryMicroUSD != 0 || !account.NextInvoiceAt.Equal(start.AddDate(0, 0, 7)) {
		t.Fatalf("account after sub-cent skip: accrued=%d carry=%d next=%s", account.AccruedMicroUSD, account.RoundingCarryMicroUSD, account.NextInvoiceAt)
	}
	invoices, _ := st.ListEnterpriseInvoices("acct-subcent", 10)
	if len(invoices) != 0 {
		t.Fatalf("invoice count = %d, want 0", len(invoices))
	}
}

func TestAdminRunEnterpriseInvoicesRejectsMalformedJSON(t *testing.T) {
	fakeStripe := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		t.Fatalf("Stripe should not be called for malformed invoice run body: %s", r.URL.Path)
	}))
	defer fakeStripe.Close()

	srv, st := stripePayoutsTestServer(t, false, fakeStripe)
	srv.SetAdminEmails([]string{"admin@example.com"})
	start := time.Now().Add(-8 * 24 * time.Hour).Truncate(time.Second)
	if err := st.UpsertEnterpriseAccount(&store.EnterpriseAccount{
		AccountID:           "acct-due",
		Status:              store.EnterpriseStatusActive,
		BillingEmail:        "billing@example.com",
		Cadence:             store.EnterpriseCadenceWeekly,
		TermsDays:           15,
		CreditLimitMicroUSD: 10_000_000,
		AccruedMicroUSD:     2_500_000,
		CurrentPeriodStart:  start,
		NextInvoiceAt:       start,
	}); err != nil {
		t.Fatalf("UpsertEnterpriseAccount: %v", err)
	}

	req := enterpriseAdminRequest(http.MethodPost, "/v1/admin/enterprise/invoices/run", `{"account_id":`)
	w := httptest.NewRecorder()
	srv.handleAdminRunEnterpriseInvoices(w, req)
	if w.Code != http.StatusBadRequest {
		t.Fatalf("status = %d: %s", w.Code, w.Body.String())
	}
	invoices, _ := st.ListEnterpriseInvoices("acct-due", 10)
	if len(invoices) != 0 {
		t.Fatalf("invoice count = %d, want 0", len(invoices))
	}
}

func TestCreateEnterpriseInvoiceUsesDeterministicIdempotency(t *testing.T) {
	var invoiceCalls int
	var idempotencyKeys []string
	fakeStripe := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		switch r.URL.Path {
		case "/v1/invoiceitems":
			_, _ = w.Write([]byte(`{"id":"ii_ent"}`))
		case "/v1/invoices":
			invoiceCalls++
			idempotencyKeys = append(idempotencyKeys, r.Header.Get("Idempotency-Key"))
			_, _ = w.Write([]byte(`{"id":"in_same","status":"draft","amount_due":250}`))
		case "/v1/invoices/in_same/finalize":
			_, _ = w.Write([]byte(`{"id":"in_same","status":"open","amount_due":250}`))
		case "/v1/invoices/in_same/send":
			_, _ = w.Write([]byte(`{"id":"in_same","status":"open","hosted_invoice_url":"https://invoice.test/in_same","amount_due":250}`))
		default:
			http.Error(w, "unexpected path", http.StatusNotFound)
		}
	}))
	defer fakeStripe.Close()

	srv, st := stripePayoutsTestServer(t, false, fakeStripe)
	start := time.Now().Add(-8 * 24 * time.Hour).Truncate(time.Second)
	account := store.EnterpriseAccount{
		AccountID:           "acct-idem",
		Status:              store.EnterpriseStatusActive,
		BillingEmail:        "billing@example.com",
		StripeCustomerID:    "cus_existing",
		Cadence:             store.EnterpriseCadenceWeekly,
		TermsDays:           15,
		CreditLimitMicroUSD: 10_000_000,
		AccruedMicroUSD:     2_500_000,
		CurrentPeriodStart:  start,
		NextInvoiceAt:       start.AddDate(0, 0, 7),
	}
	if err := st.UpsertEnterpriseAccount(&account); err != nil {
		t.Fatalf("UpsertEnterpriseAccount: %v", err)
	}

	first, err := srv.createEnterpriseInvoice(account, account.NextInvoiceAt, 250)
	if err != nil {
		t.Fatalf("first createEnterpriseInvoice: %v", err)
	}
	second, err := srv.createEnterpriseInvoice(account, account.NextInvoiceAt, 250)
	if err != nil {
		t.Fatalf("second createEnterpriseInvoice: %v", err)
	}
	if first.ID != second.ID {
		t.Fatalf("invoice IDs = %q/%q, want same", first.ID, second.ID)
	}
	if invoiceCalls != 2 || len(idempotencyKeys) != 2 || idempotencyKeys[0] == "" || idempotencyKeys[0] != idempotencyKeys[1] {
		t.Fatalf("idempotency keys/calls = %v/%d, want same non-empty key across retries", idempotencyKeys, invoiceCalls)
	}
	invoices, _ := st.ListEnterpriseInvoices("acct-idem", 10)
	if len(invoices) != 1 {
		t.Fatalf("invoice count = %d, want 1", len(invoices))
	}
}

func TestEnterpriseFinalizeFailureDoesNotCreditPayouts(t *testing.T) {
	srv, st := testBillingServer(t)
	model := "enterprise-finalize-model"
	wallet := "0xproviderwallet"
	provider := srv.registry.Register("provider-ent", nil, &protocol.RegisterMessage{
		WalletAddress: wallet,
		Models:        []protocol.ModelInfo{{ID: model}},
	})
	pr := &registry.PendingRequest{
		RequestID:            "req-ent-finalize",
		Model:                model,
		ConsumerKey:          "acct-ent",
		ReservedMicroUSD:     1_000_000,
		EnterpriseBilling:    true,
		BillingReservationID: "missing-reservation",
		ChunkCh:              make(chan string, 1),
		CompleteCh:           make(chan protocol.UsageInfo, 1),
		ErrorCh:              make(chan protocol.InferenceErrorMessage, 1),
	}
	provider.AddPending(pr)

	srv.handleComplete(provider.ID, provider, &protocol.InferenceCompleteMessage{
		Type:      protocol.TypeInferenceComplete,
		RequestID: pr.RequestID,
		Usage:     protocol.UsageInfo{PromptTokens: 1000, CompletionTokens: 500},
	})

	errMsg, ok := <-pr.ErrorCh
	if !ok || errMsg.StatusCode != http.StatusInternalServerError {
		t.Fatalf("error message = %+v, ok=%v; want billing failure", errMsg, ok)
	}
	if st.GetBalance(wallet) != 0 {
		t.Fatalf("provider wallet balance = %d, want 0", st.GetBalance(wallet))
	}
	if st.GetBalance("platform") != 0 {
		t.Fatalf("platform balance = %d, want 0", st.GetBalance("platform"))
	}
	if _, ok := <-pr.CompleteCh; ok {
		t.Fatal("CompleteCh delivered usage despite Enterprise finalize failure")
	}
}

func TestEnterpriseCommittedStreamErrorSettlesReservationAtEstimate(t *testing.T) {
	srv, st := testBillingServer(t)
	if err := st.UpsertEnterpriseAccount(&store.EnterpriseAccount{
		AccountID:           "acct-stream",
		Status:              store.EnterpriseStatusActive,
		BillingEmail:        "billing@example.com",
		Cadence:             store.EnterpriseCadenceWeekly,
		TermsDays:           15,
		CreditLimitMicroUSD: 10_000_000,
	}); err != nil {
		t.Fatalf("UpsertEnterpriseAccount: %v", err)
	}
	if err := st.ReserveEnterpriseUsage("acct-stream", "res-stream", 1_000_000); err != nil {
		t.Fatalf("ReserveEnterpriseUsage: %v", err)
	}
	pr := &registry.PendingRequest{
		RequestID:            "req-stream",
		Model:                "enterprise-stream-model",
		ConsumerKey:          "acct-stream",
		ReservedMicroUSD:     1_000_000,
		EnterpriseBilling:    true,
		BillingReservationID: "res-stream",
		ChunkCh:              make(chan string, 1),
		CompleteCh:           make(chan protocol.UsageInfo, 1),
		ErrorCh:              make(chan protocol.InferenceErrorMessage, 1),
	}
	pr.ErrorCh <- protocol.InferenceErrorMessage{RequestID: pr.RequestID, Error: "backend stopped", StatusCode: http.StatusBadGateway}

	req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", nil)
	w := httptest.NewRecorder()
	srv.handleStreamingResponseWithFirstChunk(w, req, pr, `data: {"choices":[{"delta":{"content":"partial"}}]}`)

	account, _ := st.GetEnterpriseAccount("acct-stream")
	if account.ReservedMicroUSD != 0 || account.AccruedMicroUSD != 1_000_000 {
		t.Fatalf("reserved/accrued = %d/%d, want 0/1000000", account.ReservedMicroUSD, account.AccruedMicroUSD)
	}
}

func TestEnterpriseStatusShowsRecentInvoices(t *testing.T) {
	srv, st := testBillingServer(t)
	now := time.Now().Truncate(time.Second)
	if err := st.UpsertEnterpriseAccount(&store.EnterpriseAccount{
		AccountID:           "acct-ent",
		Status:              store.EnterpriseStatusActive,
		BillingEmail:        "billing@example.com",
		Cadence:             store.EnterpriseCadenceMonthly,
		TermsDays:           30,
		CreditLimitMicroUSD: 10_000_000,
		AccruedMicroUSD:     1_000_000,
		CurrentPeriodStart:  now,
		NextInvoiceAt:       now.AddDate(0, 1, 0),
	}); err != nil {
		t.Fatalf("UpsertEnterpriseAccount: %v", err)
	}
	if err := st.CreateEnterpriseInvoice(&store.EnterpriseInvoice{
		ID:                     "inv-1",
		AccountID:              "acct-ent",
		StripeInvoiceID:        "in_1",
		StripeHostedInvoiceURL: "https://invoice.test/in_1",
		Status:                 store.EnterpriseInvoiceStatusOpen,
		PeriodStart:            now.AddDate(0, -1, 0),
		PeriodEnd:              now,
		AmountMicroUSD:         2_000_000,
		AmountCents:            200,
		TermsDays:              30,
	}); err != nil {
		t.Fatalf("CreateEnterpriseInvoice: %v", err)
	}

	req := httptest.NewRequest(http.MethodGet, "/v1/billing/enterprise/status", nil)
	req = req.WithContext(req.Context())
	req = withPrivyUser(req, &store.User{AccountID: "acct-ent", PrivyUserID: "did:privy:ent", Email: "user@example.com"})
	w := httptest.NewRecorder()
	srv.handleEnterpriseStatus(w, req)
	if w.Code != http.StatusOK {
		t.Fatalf("status = %d: %s", w.Code, w.Body.String())
	}
	var resp struct {
		Enabled        bool                      `json:"enabled"`
		RecentInvoices []store.EnterpriseInvoice `json:"recent_invoices"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &resp); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if !resp.Enabled || len(resp.RecentInvoices) != 1 {
		t.Fatalf("enterprise response = %+v", resp)
	}
}
