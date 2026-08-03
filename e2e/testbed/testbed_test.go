package testbed

import (
	"testing"
	"time"

	"github.com/stretchr/testify/assert"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

func TestEventBufferByKind(t *testing.T) {
	buf := NewEventBuffer()

	buf.Consume(Event{Kind: EventRequestStart, RequestID: "r1"})
	buf.Consume(Event{Kind: EventSegmentStart, RequestID: "r1", Segment: SegmentTotalE2E})
	buf.Consume(Event{Kind: EventSegmentEnd, RequestID: "r1", Segment: SegmentTotalE2E, Duration: 10 * time.Millisecond})
	buf.Consume(Event{Kind: EventRequestEnd, RequestID: "r1"})

	starts := buf.ByKind(EventRequestStart)
	assert.Len(t, starts, 1)

	ends := buf.ByKind(EventSegmentEnd)
	assert.Len(t, ends, 1)
	assert.Equal(t, 10*time.Millisecond, ends[0].Duration)
}

func TestEventBufferBySegment(t *testing.T) {
	buf := NewEventBuffer()

	buf.Consume(Event{Kind: EventSegmentEnd, Segment: SegmentTTFT, Duration: 100 * time.Millisecond})
	buf.Consume(Event{Kind: EventSegmentEnd, Segment: SegmentTotalE2E, Duration: 500 * time.Millisecond})
	buf.Consume(Event{Kind: EventSegmentEnd, Segment: SegmentTTFT, Duration: 200 * time.Millisecond})

	assert.Len(t, buf.BySegment(SegmentTTFT), 2)
	assert.Len(t, buf.BySegment(SegmentTotalE2E), 1)
}

func TestEventBufferByRequest(t *testing.T) {
	buf := NewEventBuffer()

	buf.Consume(Event{Kind: EventRequestStart, RequestID: "r1"})
	buf.Consume(Event{Kind: EventRequestStart, RequestID: "r2"})
	buf.Consume(Event{Kind: EventSegmentEnd, RequestID: "r1", Segment: SegmentTTFT})
	buf.Consume(Event{Kind: EventSegmentEnd, RequestID: "r2", Segment: SegmentTotalE2E})

	assert.Len(t, buf.ByRequest("r1"), 2)
	assert.Len(t, buf.ByRequest("r2"), 2)
}

func TestEventBufferReset(t *testing.T) {
	buf := NewEventBuffer()
	buf.Consume(Event{Kind: EventRequestStart, RequestID: "r1"})

	assert.Len(t, buf.Events(), 1)

	buf.Reset()
	assert.Len(t, buf.Events(), 0)
}

func TestEventFan(t *testing.T) {
	b1 := NewEventBuffer()
	b2 := NewEventBuffer()
	fan := EventFan{b1, b2}

	fan.Consume(Event{Kind: EventRequestStart, RequestID: "r1"})

	assert.Len(t, b1.Events(), 1)
	assert.Len(t, b2.Events(), 1)
}

func TestEventSchemaVersion(t *testing.T) {
	buf := NewEventBuffer()
	inst := NewInstrument(buf)
	rid := inst.NewRequestID()
	inst.RequestStart(rid)

	events := buf.Events()
	assert.Equal(t, SchemaVersion, events[0].SchemaVersion)
}

func TestDefaultConfigs(t *testing.T) {
	cfg := DefaultTestConfig()
	assert.Equal(t, "mlx-community/gemma-3-270m", cfg.Model.ModelID)
	assert.Equal(t, TrustNone, cfg.Provider.TrustLevel)
	assert.Equal(t, 64, cfg.Request.PromptTokens)
	assert.Equal(t, 128, cfg.Request.MaxTokens)
	assert.Equal(t, 0.0, cfg.Request.Temperature)
	assert.True(t, cfg.Request.Streaming)
	assert.Equal(t, 1, cfg.Request.Concurrency)
	assert.Equal(t, 10, cfg.Request.TotalRequests)

	// v0.7.5 ONE-ENGINE: the suite default is the CBv2 default fixture
	// (gpt-oss-20b), overridable via DARKBLOOM_TESTBED_MODEL — pin the env
	// so both helper branches are covered deterministically.
	t.Setenv("DARKBLOOM_TESTBED_MODEL", "")
	assert.Equal(t, "mlx-community/gpt-oss-20b-MXFP4-Q8", DefaultTestModelID())
	t.Setenv("DARKBLOOM_TESTBED_MODEL", "org/custom-model")
	assert.Equal(t, "org/custom-model", DefaultTestModelID())
	t.Setenv("DARKBLOOM_TESTBED_MODEL", "")

	// Secondary (multi-model) fixture: gemma-4-26B QAT by default,
	// overridable via DARKBLOOM_TESTBED_MODEL_B.
	t.Setenv("DARKBLOOM_TESTBED_MODEL_B", "")
	assert.Equal(t, "mlx-community/gemma-4-26B-A4B-it-qat-4bit", SecondaryTestModelID())
	t.Setenv("DARKBLOOM_TESTBED_MODEL_B", "org/custom-model-b")
	assert.Equal(t, "org/custom-model-b", SecondaryTestModelID())
	t.Setenv("DARKBLOOM_TESTBED_MODEL_B", "")

	sc := DefaultSuiteConfig()
	assert.Equal(t, 1, len(sc.ModelSpecs))
	assert.Equal(t, DefaultTestModelID(), sc.ModelSpecs[0].ModelID)
	assert.Equal(t, 1, sc.ModelSpecs[0].NumProviders)
	assert.Equal(t, 1, sc.NumUsers)
	assert.Equal(t, 1, sc.TotalProviders())
	assert.Equal(t, DefaultTestModelID(), sc.PrimaryModelID())
	assert.Equal(t, []string{DefaultTestModelID()}, sc.AllModelIDs())

	multiSpec := SuiteConfig{
		ModelSpecs: []ModelSpec{
			{ModelID: "model-a", NumProviders: 4},
			{ModelID: "model-b", NumProviders: 3},
		},
		NumUsers: 5,
	}
	assert.Equal(t, 7, multiSpec.TotalProviders())
	assert.Equal(t, []string{"model-a", "model-b"}, multiSpec.AllModelIDs())
	assert.Equal(t, "model-a", multiSpec.PrimaryModelID())
}

// TestReportedPrivacyCapabilities pins the accessor contract the
// mixed-version gate depends on: the three registration outcomes stay
// distinguishable, and the caller cannot reach back into suite state.
func TestReportedPrivacyCapabilities(t *testing.T) {
	s := &Suite{privacyAtRegistration: map[string]*protocol.PrivacyCapabilities{
		"reported": {TextBackendInprocess: true, SIPEnabled: true},
		"silent":   nil,
	}}

	caps, ok := s.ReportedPrivacyCapabilities("reported")
	assert.True(t, ok)
	if assert.NotNil(t, caps) {
		assert.True(t, caps.TextBackendInprocess)
		assert.True(t, caps.SIPEnabled)
	}

	// A provider that registered without a privacy_capabilities block is a
	// real outcome and must NOT look like an unknown provider.
	silent, ok := s.ReportedPrivacyCapabilities("silent")
	assert.True(t, ok, "provider registered; it simply reported no block")
	assert.Nil(t, silent)

	unknown, ok := s.ReportedPrivacyCapabilities("never-registered")
	assert.False(t, ok)
	assert.Nil(t, unknown)

	// The returned block is a copy: mutating it must not rewrite the snapshot,
	// or one subtest could launder a value into another's assertions.
	caps.TextBackendInprocess = false
	again, _ := s.ReportedPrivacyCapabilities("reported")
	assert.True(t, again.TextBackendInprocess, "accessor leaked its internal pointer")
}
