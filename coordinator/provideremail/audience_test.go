package provideremail

import (
	"strings"
	"testing"
	"time"
)

func testCampaign() Campaign {
	return Campaign{ID: "provider-update", Audience: "provider_update", MinimumVersion: "0.9.4", ActiveWithinDays: 30, OSMaxAgeDays: 7,
		Message: Message{From: "Darkbloom <providers@example.com>", ReplyTo: "support@example.com", Subject: "Please update your provider", Severity: "recommended", Body: "Install the supported release.", InstructionsURL: "https://example.com/providers"}}
}

func testMachine(now time.Time, id string) Machine {
	return Machine{ID: id, AccountID: "owner", Email: "owner@example.com", Source: "live_registration", LastSeen: now,
		ProviderVersion: "0.9.3", OSVersion: "26.5", OSSource: "registration_report", OSObservedAt: now}
}

func TestAudienceSelection(t *testing.T) {
	now := time.Now().UTC()
	c := testCampaign()
	cases := []struct {
		name  string
		edit  func(*Machine)
		field string
	}{
		{"outdated", func(m *Machine) {}, "needs"},
		{"current", func(m *Machine) { m.ProviderVersion = "0.9.4" }, "target"},
		{"numeric", func(m *Machine) { m.ProviderVersion = "0.10.0" }, "target"},
		{"prerelease", func(m *Machine) { m.ProviderVersion = "0.9.4-rc.1" }, "needs"},
		{"unknown", func(m *Machine) { m.ProviderVersion = "unknown" }, "unknown"},
		{"inactive", func(m *Machine) { m.LastSeen = now.AddDate(0, 0, -31) }, "inactive"},
		{"anonymous", func(m *Machine) { m.AccountID = "" }, "owner"},
		{"historical", func(m *Machine) { m.Source = "historical_registration" }, "historical"},
		{"missing email", func(m *Machine) { m.Email = "" }, "email"},
		{"display-name email", func(m *Machine) { m.Email = "Someone <owner@example.com>" }, "email"},
	}
	for _, tt := range cases {
		t.Run(tt.name, func(t *testing.T) {
			m := testMachine(now, "machine")
			tt.edit(&m)
			a, err := BuildAudience(c, Snapshot{CapturedAt: now, Machines: []Machine{m}}, now)
			if err != nil {
				t.Fatal(err)
			}
			values := map[string]int{"needs": a.Counts.Recipients, "target": a.Counts.AtTarget, "unknown": a.Counts.UnknownVersion,
				"inactive": a.Counts.Inactive, "owner": a.Counts.UnknownOwner, "historical": a.Counts.Historical, "email": a.Counts.MissingEmail}
			if values[tt.field] != 1 {
				t.Fatalf("counts = %+v", a.Counts)
			}
			if tt.field != "needs" && len(a.Recipients) != 0 {
				t.Fatal("excluded machine became a recipient")
			}
		})
	}
}

func TestAudienceGroupsMachinesAndSharedEmail(t *testing.T) {
	now := time.Now().UTC()
	a, b, c := testMachine(now, "a"), testMachine(now, "b"), testMachine(now, "c")
	b.Email = " OWNER@EXAMPLE.COM "
	c.AccountID = "second-account"
	result, err := BuildAudience(testCampaign(), Snapshot{CapturedAt: now, Machines: []Machine{a, b, c}}, now)
	if err != nil {
		t.Fatal(err)
	}
	if len(result.Recipients) != 1 || result.Recipients[0].AffectedMachines != 3 || len(result.Recipients[0].AccountIDs) != 2 {
		t.Fatalf("unexpected grouped recipients: %+v", result.Recipients)
	}
}

func TestMacOSUnknownAndFreshness(t *testing.T) {
	now := time.Now().UTC()
	c := testCampaign()
	c.Audience = "macos_update"
	c.MinimumVersion = "27.0"
	for _, tc := range []struct {
		os, source      string
		age             time.Duration
		unknown, target int
	}{
		{"26.5", "registration_report", time.Hour, 0, 0},
		{"27.0.0", "app_attest_assertion_report", time.Hour, 0, 1},
		{"27.0 beta", "registration_report", time.Hour, 1, 0},
		{"", "registration_report", time.Hour, 1, 0},
		{"26.5", "unknown", time.Hour, 1, 0},
		{"26.5", "registration_report", 8 * 24 * time.Hour, 1, 0},
		{"26.5", "registration_report", -time.Hour, 1, 0},
	} {
		m := testMachine(now, "machine")
		m.OSVersion, m.OSSource, m.OSObservedAt = tc.os, tc.source, now.Add(-tc.age)
		a, err := BuildAudience(c, Snapshot{CapturedAt: now, Machines: []Machine{m}}, now)
		if err != nil {
			t.Fatal(err)
		}
		if a.Counts.UnknownVersion != tc.unknown || a.Counts.AtTarget != tc.target || a.Counts.Recipients != 1-tc.unknown-tc.target {
			t.Fatalf("%+v: %+v", tc, a.Counts)
		}
	}
}

func TestRejectsUnsafeSnapshotAndConfig(t *testing.T) {
	now := time.Now().UTC()
	c := testCampaign()
	m := testMachine(now, "machine")
	for _, s := range []Snapshot{
		{CapturedAt: now.Add(-16 * time.Minute)}, {CapturedAt: now.Add(2 * time.Minute)},
		{CapturedAt: now, Machines: []Machine{m, m}}, {CapturedAt: now, Machines: []Machine{{}}},
	} {
		if _, err := BuildAudience(c, s, now); err == nil {
			t.Fatal("accepted invalid snapshot")
		}
	}
	for _, edit := range []func(*Campaign){
		func(c *Campaign) { c.MinimumVersion = "latest" }, func(c *Campaign) { c.Audience = "typo" },
		func(c *Campaign) { c.Message.Severity = "required" }, func(c *Campaign) { c.Message.From = "a@example.com\r\nBcc:b@example.com" },
		func(c *Campaign) { c.Message.InstructionsURL = "javascript:alert(1)" }, func(c *Campaign) { c.OSMaxAgeDays = 0 },
	} {
		copy := c
		edit(&copy)
		if err := copy.Validate(); err == nil {
			t.Fatal("accepted invalid campaign")
		}
	}
	if _, err := DecodeCampaign(strings.NewReader(`{"typo":1}`)); err == nil {
		t.Fatal("unknown field accepted")
	}
}

func TestPolicyChangesCreateDistinctSegments(t *testing.T) {
	c := testCampaign()
	original := c.SegmentName()
	c.Message.Body = "New wording"
	if c.SegmentName() != original {
		t.Fatal("copy changed audience")
	}
	c.MinimumVersion = "0.9.5"
	if c.SegmentName() == original {
		t.Fatal("target reused old segment")
	}
}

func TestResendResourceNameLimits(t *testing.T) {
	c := testCampaign()
	c.ID = strings.Repeat("a", 30)
	if err := c.Validate(); err != nil {
		t.Fatal(err)
	}
	if len(c.DraftName()) > 70 || len(c.SegmentName()) > 70 {
		t.Fatal("Resend resource name exceeds limit")
	}
	before := c.DraftName()
	c.MinimumVersion = "0.9.5"
	if c.DraftName() == before {
		t.Fatal("draft name ignores target change")
	}
}

func TestRenderEscapesAndPreservesUnsubscribe(t *testing.T) {
	c := testCampaign()
	c.Message.Body = `<script>alert("hello")</script>`
	d, err := Render(c, false)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(d.HTML, "<script>") || !strings.Contains(d.HTML, "&lt;script&gt;") || !strings.Contains(d.HTML, "{{{RESEND_UNSUBSCRIBE_URL}}}") || strings.Contains(d.HTML, "#ZgotmplZ") {
		t.Fatal(d.HTML)
	}
	d, err = Render(c, true)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(d.HTML, "RESEND_UNSUBSCRIBE") || !strings.Contains(d.HTML, "Integration test only") {
		t.Fatal(d.HTML)
	}
}
