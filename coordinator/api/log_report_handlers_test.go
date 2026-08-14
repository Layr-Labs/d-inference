package api

import (
	"bytes"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/store"
)

const testLogReportSerial = "TEST-SERIAL"

func newLogReportTestServer() (*Server, *store.MemoryStore) {
	memoryStore := store.NewMemory(store.Config{})
	return &Server{
		store:    memoryStore,
		logger:   quietLogger(),
		adminKey: "test-admin-key",
	}, memoryStore
}

func TestProviderLogUploadStoresExplicitReport(t *testing.T) {
	srv, memoryStore := newLogReportTestServer()
	reportData := []byte(`{"eventMessage":"Provider starting"}` + "\n")
	req := httptest.NewRequest(
		http.MethodPost,
		"/v1/provider/log-report?serial="+testLogReportSerial,
		bytes.NewReader(reportData),
	)
	recorder := httptest.NewRecorder()

	srv.handleUploadLogReport(recorder, req)

	if recorder.Code != http.StatusCreated {
		t.Fatalf("status = %d, want %d; body=%s", recorder.Code, http.StatusCreated, recorder.Body.String())
	}
	reports, err := memoryStore.GetLogReports(testLogReportSerial, 10)
	if err != nil {
		t.Fatalf("GetLogReports: %v", err)
	}
	if len(reports) != 1 {
		t.Fatalf("stored reports = %d, want 1", len(reports))
	}
	stored, err := memoryStore.GetLogReport(reports[0].ID)
	if err != nil {
		t.Fatalf("GetLogReport: %v", err)
	}
	if !bytes.Equal(stored.LogData, reportData) {
		t.Fatalf("stored report = %q, want %q", stored.LogData, reportData)
	}
}

func TestProviderLogUploadValidatesInputAndSize(t *testing.T) {
	testCases := []struct {
		name       string
		path       string
		body       *strings.Reader
		wantStatus int
	}{
		{
			name:       "missing serial",
			path:       "/v1/provider/log-report",
			body:       strings.NewReader("diagnostic"),
			wantStatus: http.StatusBadRequest,
		},
		{
			name:       "empty body",
			path:       "/v1/provider/log-report?serial=" + testLogReportSerial,
			body:       strings.NewReader(""),
			wantStatus: http.StatusBadRequest,
		},
		{
			name:       "body exceeds limit",
			path:       "/v1/provider/log-report?serial=" + testLogReportSerial,
			body:       strings.NewReader(strings.Repeat("x", maxLogReportBodySize+1)),
			wantStatus: http.StatusRequestEntityTooLarge,
		},
	}

	for _, testCase := range testCases {
		t.Run(testCase.name, func(t *testing.T) {
			srv, memoryStore := newLogReportTestServer()
			req := httptest.NewRequest(http.MethodPost, testCase.path, testCase.body)
			recorder := httptest.NewRecorder()

			srv.handleUploadLogReport(recorder, req)

			if recorder.Code != testCase.wantStatus {
				t.Fatalf("status = %d, want %d", recorder.Code, testCase.wantStatus)
			}
			reports, err := memoryStore.GetLogReports(testLogReportSerial, 10)
			if err != nil {
				t.Fatalf("GetLogReports: %v", err)
			}
			if len(reports) != 0 {
				t.Fatalf("invalid upload stored %d report(s)", len(reports))
			}
		})
	}
}

func TestAdminCanListAndRetrieveExplicitLogReport(t *testing.T) {
	srv, memoryStore := newLogReportTestServer()
	reportData := []byte("bounded provider diagnostics\n")
	if err := memoryStore.StoreLogReport(testLogReportSerial, "provider-1", "account-1", reportData); err != nil {
		t.Fatalf("StoreLogReport: %v", err)
	}
	reports, err := memoryStore.GetLogReports(testLogReportSerial, 10)
	if err != nil || len(reports) != 1 {
		t.Fatalf("GetLogReports = %v, %v", reports, err)
	}

	listReq := httptest.NewRequest(
		http.MethodGet,
		"/v1/admin/log-reports?serial="+testLogReportSerial,
		nil,
	)
	listReq.Header.Set("Authorization", "Bearer test-admin-key")
	listRecorder := httptest.NewRecorder()
	srv.handleListLogReports(listRecorder, listReq)
	if listRecorder.Code != http.StatusOK {
		t.Fatalf("list status = %d, want %d", listRecorder.Code, http.StatusOK)
	}
	if strings.Contains(listRecorder.Body.String(), string(reportData)) {
		t.Fatal("list response exposed the report body")
	}

	getReq := httptest.NewRequest(http.MethodGet, "/v1/admin/log-reports/1", nil)
	getReq.SetPathValue("id", "1")
	getReq.Header.Set("Authorization", "Bearer test-admin-key")
	getRecorder := httptest.NewRecorder()
	srv.handleGetLogReport(getRecorder, getReq)
	if getRecorder.Code != http.StatusOK {
		t.Fatalf("get status = %d, want %d", getRecorder.Code, http.StatusOK)
	}
	if getRecorder.Body.String() != string(reportData) {
		t.Fatalf("get body = %q, want %q", getRecorder.Body.String(), reportData)
	}
	if contentType := getRecorder.Header().Get("Content-Type"); contentType != "text/plain; charset=utf-8" {
		t.Fatalf("Content-Type = %q", contentType)
	}
}

func TestAdminLogReportRetrievalRequiresAdmin(t *testing.T) {
	srv, _ := newLogReportTestServer()
	req := httptest.NewRequest(
		http.MethodGet,
		"/v1/admin/log-reports?serial="+testLogReportSerial,
		nil,
	)
	recorder := httptest.NewRecorder()

	srv.handleListLogReports(recorder, req)

	if recorder.Code != http.StatusForbidden {
		t.Fatalf("status = %d, want %d", recorder.Code, http.StatusForbidden)
	}
}
