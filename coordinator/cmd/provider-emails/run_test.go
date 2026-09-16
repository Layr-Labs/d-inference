package main

import (
	"bytes"
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/provideremail"
)

func TestPreviewAndTestDryRunNeedNoCredentials(t *testing.T) {
	dir := t.TempDir()
	campaign := filepath.Join(dir, "campaign.json")
	snapshot := filepath.Join(dir, "snapshot.json")
	c := provideremail.Campaign{ID: "test", Audience: "provider_update", MinimumVersion: "0.9.4", ActiveWithinDays: 30, OSMaxAgeDays: 7, Message: provideremail.Message{From: "providers@example.com", ReplyTo: "support@example.com", Subject: "Provider update", Body: "Please update.", Severity: "recommended", InstructionsURL: "https://example.com/update"}}
	raw, _ := json.Marshal(c)
	if err := os.WriteFile(campaign, raw, 0600); err != nil {
		t.Fatal(err)
	}
	now := time.Now().UTC()
	raw, _ = json.Marshal(provideremail.Snapshot{CapturedAt: now, Machines: []provideremail.Machine{{ID: "private-machine", AccountID: "private-account", Email: "private@example.com", Source: "live_registration", ProviderVersion: "0.9.3", LastSeen: now}}})
	if err := os.WriteFile(snapshot, raw, 0600); err != nil {
		t.Fatal(err)
	}
	report := filepath.Join(dir, "report.json")
	html := filepath.Join(dir, "preview.html")
	var output bytes.Buffer
	getenv := func(string) string { return "" }
	if err := run(context.Background(), []string{"preview", "-config", campaign, "-snapshot", snapshot, "-report", report, "-html", html}, &output, getenv); err != nil {
		t.Fatal(err)
	}
	if strings.Contains(output.String(), "private") || !strings.Contains(output.String(), `"recipients":1`) {
		t.Fatal(output.String())
	}
	st, err := os.Stat(report)
	if err != nil || st.Mode().Perm() != 0600 {
		t.Fatalf("private report permissions: %v %v", st, err)
	}
	output.Reset()
	if err := run(context.Background(), []string{"test", "-config", campaign, "-to", "tester@example.com"}, &output, getenv); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(output.String(), "no email sent") {
		t.Fatal(output.String())
	}
	if err := run(context.Background(), []string{"test", "-config", campaign, "-to", "a@example.com,b@example.com", "-apply"}, &output, getenv); err == nil {
		t.Fatal("accepted multiple test recipients")
	}
	if err := run(context.Background(), []string{"preview", "-config", campaign, "-apply"}, &output, getenv); err == nil {
		t.Fatal("accepted preview mutation")
	}
}

func TestPrivateFileRefusesOverwriteOrSymlink(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "file")
	if err := writePrivateFile(path, []byte("original")); err != nil {
		t.Fatal(err)
	}
	if err := writePrivateFile(path, []byte("replacement")); err == nil {
		t.Fatal("overwrote report")
	}
	link := filepath.Join(dir, "link")
	if err := os.Symlink(path, link); err != nil {
		t.Fatal(err)
	}
	if err := writePrivateFile(link, []byte("replacement")); err == nil {
		t.Fatal("followed symlink")
	}
}
