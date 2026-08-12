package api

import (
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

type logReportReadSpy struct {
	reads int
}

func (b *logReportReadSpy) Read([]byte) (int, error) {
	b.reads++
	return 0, io.EOF
}

func (b *logReportReadSpy) Close() error { return nil }

func TestProviderLogUploadIsDisabledBeforeBodyOrStoreAccess(t *testing.T) {
	body := &logReportReadSpy{}
	srv := &Server{}
	req := httptest.NewRequest(
		http.MethodPost,
		"/v1/provider/log-report?serial=SERIAL_LEAK_SENTINEL",
		nil,
	)
	req.Body = body
	recorder := httptest.NewRecorder()

	srv.handleUploadLogReport(recorder, req)

	if recorder.Code != http.StatusGone {
		t.Fatalf("status = %d, want %d", recorder.Code, http.StatusGone)
	}
	if strings.Contains(recorder.Body.String(), "LEAK_SENTINEL") {
		t.Fatalf("request data reflected in response: %s", recorder.Body.String())
	}
	if body.reads != 0 {
		t.Fatalf("request body was read %d time(s)", body.reads)
	}
}

func TestHistoricalLogReportRetrievalIsDisabledBeforeStoreAccess(t *testing.T) {
	for _, testCase := range []struct {
		name    string
		path    string
		handler func(*Server, http.ResponseWriter, *http.Request)
	}{
		{name: "list", path: "/v1/admin/log-reports?serial=SERIAL_LEAK_SENTINEL", handler: (*Server).handleListLogReports},
		{name: "get", path: "/v1/admin/log-reports/42", handler: (*Server).handleGetLogReport},
	} {
		t.Run(testCase.name, func(t *testing.T) {
			// A nil store deliberately makes any regression to historical data
			// access panic. Admin auth must succeed before the fixed 410 response.
			srv := &Server{adminKey: "test-admin-key"}
			req := httptest.NewRequest(http.MethodGet, testCase.path, nil)
			req.Header.Set("Authorization", "Bearer test-admin-key")
			recorder := httptest.NewRecorder()

			testCase.handler(srv, recorder, req)

			if recorder.Code != http.StatusGone {
				t.Fatalf("status = %d, want %d", recorder.Code, http.StatusGone)
			}
			if strings.Contains(recorder.Body.String(), "LEAK_SENTINEL") {
				t.Fatalf("request data reflected in response: %s", recorder.Body.String())
			}
		})
	}
}
