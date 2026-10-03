package operations

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/api/access"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
)

func newLogReportTestServer() (*Handler, *memory.MemoryStore) {
	memoryStore := memory.NewMemory(store.Config{})
	auth := access.New(memoryStore, slog.New(slog.NewTextHandler(io.Discard, nil)), 1<<20, access.Hooks{})
	auth.SetAdminKey("test-admin-key")
	return &Handler{
		store:  memoryStore,
		logger: slog.New(slog.NewTextHandler(io.Discard, nil)),
		access: auth,
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

	srv.HandleUploadLogReport(recorder, req)

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
		{
			name:       "legacy identity query requires upgrade",
			path:       "/v1/provider/log-report?serial=PRIVATE-SERIAL",
			body:       strings.NewReader("diagnostics"),
			wantStatus: http.StatusUpgradeRequired,
		},
	}

	for _, testCase := range testCases {
		t.Run(testCase.name, func(t *testing.T) {
			srv, memoryStore := newLogReportTestServer()
			req := httptest.NewRequest(http.MethodPost, testCase.path, testCase.body)
			recorder := httptest.NewRecorder()

			srv.HandleUploadLogReport(recorder, req)

			if recorder.Code != testCase.wantStatus {
				t.Fatalf("status = %d, want %d; body=%s", recorder.Code, testCase.wantStatus, recorder.Body.String())
			}
			if strings.Contains(recorder.Body.String(), "PRIVATE-SERIAL") {
				t.Fatalf("rejected upload echoed device identity: %s", recorder.Body.String())
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
	srv.HandleGetLogReport(getRecorder, getReq)
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

	srv.HandleGetLogReport(recorder, req)

	if recorder.Code != http.StatusForbidden {
		t.Fatalf("status = %d, want %d", recorder.Code, http.StatusForbidden)
	}
}
