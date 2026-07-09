package testbed

import (
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
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

	sc := DefaultSuiteConfig()
	assert.Equal(t, 1, len(sc.ModelSpecs))
	assert.Equal(t, DefaultModelID(), sc.ModelSpecs[0].ModelID)
	assert.Equal(t, 1, sc.ModelSpecs[0].NumProviders)
	assert.Equal(t, 1, sc.NumUsers)
	assert.Equal(t, 1, sc.TotalProviders())
	assert.Equal(t, DefaultModelID(), sc.PrimaryModelID())
	assert.Equal(t, []string{DefaultModelID()}, sc.AllModelIDs())

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

func TestDefaultModelIDEnvOverride(t *testing.T) {
	// Clear both knobs to observe the built-in default regardless of the
	// outer environment (t.Setenv restores the originals afterwards).
	t.Setenv("TESTBED_MODEL", "")
	t.Setenv("TESTBED_MODEL_ID", "")
	assert.Equal(t, builtinDefaultModelID, DefaultModelID())
	assert.Equal(t, "gpt-oss-20b", builtinDefaultModelID)

	t.Setenv("TESTBED_MODEL_ID", "legacy-model")
	assert.Equal(t, "legacy-model", DefaultModelID(), "legacy TESTBED_MODEL_ID alias should still work")

	t.Setenv("TESTBED_MODEL", "override-model")
	assert.Equal(t, "override-model", DefaultModelID(), "TESTBED_MODEL takes precedence")

	sc := SuiteConfig{}
	assert.Equal(t, "override-model", sc.PrimaryModelID(), "empty suite config resolves through DefaultModelID")
}

func TestKnownModelSizesProdEntries(t *testing.T) {
	assert.Equal(t, "15.6 GB", KnownModelSizes["gemma-4-26b-qat-4bit"])
	assert.Equal(t, "12.1 GB", KnownModelSizes["gpt-oss-20b"])
}
