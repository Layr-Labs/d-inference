package api_test

import (
	. "github.com/eigeninference/d-inference/coordinator/api"
	"path/filepath"
	"testing"
)

func TestSnapshotModeRequiresSeparateDurableState(t *testing.T) {
	dir := t.TempDir()
	snapshot := filepath.Join(dir, "current.json")
	state := filepath.Join(dir, "accepted.json")
	for _, tc := range []struct {
		name  string
		cfg   ServerConfig
		valid bool
	}{
		{"disabled", ServerConfig{}, true},
		{"missing state", ServerConfig{AnalyticsSnapshotPath: snapshot}, false},
		{"relative state", ServerConfig{AnalyticsSnapshotPath: snapshot, AnalyticsSnapshotStatePath: "accepted.json"}, false},
		{"same file", ServerConfig{AnalyticsSnapshotPath: snapshot, AnalyticsSnapshotStatePath: snapshot}, false},
		{"state without snapshot", ServerConfig{AnalyticsSnapshotStatePath: state}, false},
		{"separate paths", ServerConfig{AnalyticsSnapshotPath: snapshot, AnalyticsSnapshotStatePath: state}, true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if err := tc.cfg.CheckAnalyticsSnapshot(); (err == nil) != tc.valid {
				t.Fatalf("valid=%v error=%v", tc.valid, err)
			}
		})
	}
}
