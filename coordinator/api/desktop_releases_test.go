package api

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
)

func TestDesktopReleaseFeed(t *testing.T) {
	srv, st := testServer(t)
	srv.SetMinProviderVersion("0.9.15")
	for i := 0; i < 35; i++ {
		release := &store.Release{Version: fmt.Sprintf("0.9.%d", i), Platform: defaultReleasePlatform,
			CreatedAt: time.Now().Add(time.Duration(i) * time.Second), Changelog: "Faster recovery", BinaryHash: "private-fixture-hash", URL: "private-fixture-url"}
		if err := st.SetRelease(release); err != nil {
			t.Fatal(err)
		}
	}
	if err := st.SetRelease(&store.Release{Version: "3.0.0", Platform: "other-platform", Changelog: "exclude-this-platform"}); err != nil {
		t.Fatal(err)
	}
	server := httptest.NewServer(srv.Handler())
	defer server.Close()
	read := func() desktopReleaseFeed {
		t.Helper()
		response, err := http.Get(server.URL + "/v1/releases/desktop")
		if err != nil {
			t.Fatal(err)
		}
		defer response.Body.Close()
		if response.StatusCode != 200 {
			t.Fatal(response.Status)
		}
		var body json.RawMessage
		if err := json.NewDecoder(response.Body).Decode(&body); err != nil {
			t.Fatal(err)
		}
		for _, secret := range []string{"private-fixture", "exclude-this-platform"} {
			if strings.Contains(string(body), secret) {
				t.Fatalf("unexpected field in feed: %s", body)
			}
		}
		var feed desktopReleaseFeed
		if err := json.Unmarshal(body, &feed); err != nil {
			t.Fatal(err)
		}
		return feed
	}
	feed := read()
	if len(feed.History) != 30 || feed.History[0].Version != "0.9.34" || feed.MinimumProviderVersion != "0.9.15" {
		t.Fatalf("feed = %+v", feed)
	}
	if err := st.DeleteRelease("0.9.34", defaultReleasePlatform); err != nil {
		t.Fatal(err)
	}
	srv.invalidateReleaseCaches(defaultReleasePlatform)
	srv.SetMinProviderVersion("0.9.20")
	feed = read()
	if feed.History[0].Active || feed.MinimumProviderVersion != "0.9.20" {
		t.Fatalf("stale release policy: %+v", feed)
	}
}

func TestDesktopReleaseFeedEmpty(t *testing.T) {
	srv, _ := testServer(t)
	recorder := httptest.NewRecorder()
	srv.Handler().ServeHTTP(recorder, httptest.NewRequest(http.MethodGet, "/v1/releases/desktop", nil))
	if recorder.Code != 200 || !strings.Contains(recorder.Body.String(), `"history":[]`) || !strings.Contains(recorder.Body.String(), `"minimum_provider_version":""`) {
		t.Fatal(recorder.Body.String())
	}
}
