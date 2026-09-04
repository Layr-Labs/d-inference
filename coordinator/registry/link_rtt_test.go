package registry

import (
	"math"
	"testing"
	"time"
)

func TestRecordLinkRTTEWMA(t *testing.T) {
	p := &Provider{ID: "rtt"}
	if s := p.LinkRTT(); s.Samples != 0 || s.EWMAMs != 0 {
		t.Fatalf("fresh provider RTT = %+v", s)
	}
	p.RecordLinkRTT(100 * time.Millisecond)
	s := p.LinkRTT()
	if s.Samples != 1 || s.EWMAMs != 100 || s.LastMs != 100 || s.LastAt.IsZero() {
		t.Fatalf("first sample seeds the EWMA: %+v", s)
	}
	p.RecordLinkRTT(200 * time.Millisecond)
	s = p.LinkRTT()
	want := linkRTTAlpha*200 + (1-linkRTTAlpha)*100
	if math.Abs(s.EWMAMs-want) > 1e-9 || s.LastMs != 200 || s.Samples != 2 {
		t.Fatalf("EWMA after second sample = %+v, want ewma %v", s, want)
	}
	// Negative durations are ignored.
	p.RecordLinkRTT(-time.Second)
	if p.LinkRTT().Samples != 2 {
		t.Fatal("negative RTT must be ignored")
	}
	// LinkStats carries the same figures.
	if ls := p.LinkStats(); ls.RTT.Samples != 2 || ls.RTT.LastMs != 200 {
		t.Fatalf("LinkStats RTT = %+v", ls.RTT)
	}
}

func TestLinkPingTimeoutLatch(t *testing.T) {
	p := &Provider{ID: "rtt"}
	if p.LinkPingTimedOut() {
		t.Fatal("fresh provider must not be timed out")
	}
	p.MarkLinkPingTimeout()
	if !p.LinkPingTimedOut() {
		t.Fatal("latch did not set")
	}
	var nilP *Provider
	nilP.MarkLinkPingTimeout()
	if nilP.LinkPingTimedOut() {
		t.Fatal("nil provider must report false")
	}
	nilP.SetReadLoopBusy(true)
	if nilP.ReadLoopBusy() {
		t.Fatal("nil provider must report not busy")
	}
}
