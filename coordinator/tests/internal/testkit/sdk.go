package testkit

import (
	"errors"
	"net/http/httptest"
	"testing"

	openai "github.com/openai/openai-go"
	"github.com/openai/openai-go/option"
)

func NewSDKClientForCompat(t testing.TB, ts *httptest.Server) *openai.Client {
	t.Helper()
	client := openai.NewClient(option.WithBaseURL(ts.URL+"/v1"), option.WithAPIKey("test-key"))
	return &client
}

func AsSDKError(err error) *openai.Error {
	var apiErr *openai.Error
	if errors.As(err, &apiErr) {
		return apiErr
	}
	return nil
}
