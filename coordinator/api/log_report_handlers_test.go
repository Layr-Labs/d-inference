package api

import (
	"bytes"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/store"
)

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
		"/v1/provider/log-report",
		bytes.NewReader(reportData),
	)
	recorder := httptest.NewRecorder()

	srv.handleUploadLogReport(recorder, req)

	if recorder.Code != http.StatusCreated {
		t.Fatalf("status = %d, want %d; body=%s", recorder.Code, http.StatusCreated, recorder.Body.String())
	}
	var upload struct {
		ReportID int64 `json:"report_id"`
	}
	if err := json.Unmarshal(recorder.Body.Bytes(), &upload); err != nil {
		t.Fatalf("decode upload response: %v", err)
	}
	if upload.ReportID <= 0 {
		t.Fatalf("report_id = %d, want positive id", upload.ReportID)
	}
	if strings.Contains(recorder.Body.String(), `"serial"`) {
		t.Fatalf("upload response exposed serial data: %s", recorder.Body.String())
	}
	stored, err := memoryStore.GetLogReport(upload.ReportID)
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
			name:       "empty body",
			path:       "/v1/provider/log-report",
			body:       strings.NewReader(""),
			wantStatus: http.StatusBadRequest,
		},
		{
			name:       "body exceeds limit",
			path:       "/v1/provider/log-report",
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
			if _, err := memoryStore.GetLogReport(1); err == nil {
				t.Fatal("invalid upload was stored")
			}
		})
	}
}

func TestAdminCanRetrieveExplicitLogReportByID(t *testing.T) {
	srv, memoryStore := newLogReportTestServer()
	reportData := []byte("bounded provider diagnostics\n")
	reportID, err := memoryStore.StoreLogReport("account-1", reportData)
	if err != nil {
		t.Fatalf("StoreLogReport: %v", err)
	}

	getReq := httptest.NewRequest(http.MethodGet, fmt.Sprintf("/v1/admin/log-reports/%d", reportID), nil)
	getReq.SetPathValue("id", fmt.Sprint(reportID))
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
	req := httptest.NewRequest(http.MethodGet, "/v1/admin/log-reports/1", nil)
	req.SetPathValue("id", "1")
	recorder := httptest.NewRecorder()

	srv.handleGetLogReport(recorder, req)

	if recorder.Code != http.StatusForbidden {
		t.Fatalf("status = %d, want %d", recorder.Code, http.StatusForbidden)
	}
}

func TestAdminLogReportSerialListRouteIsRemoved(t *testing.T) {
	srv, _ := newLogReportTestServer()
	req := httptest.NewRequest(http.MethodGet, "/v1/admin/log-reports?serial=PRIVATE-SERIAL", nil)
	req.Header.Set("Authorization", "Bearer test-admin-key")
	recorder := httptest.NewRecorder()

	srv.Handler().ServeHTTP(recorder, req)

	if recorder.Code != http.StatusNotFound {
		t.Fatalf("status = %d, want %d; body=%s", recorder.Code, http.StatusNotFound, recorder.Body.String())
	}
	if strings.Contains(recorder.Body.String(), "PRIVATE-SERIAL") {
		t.Fatalf("removed route echoed device identity: %s", recorder.Body.String())
	}
}
