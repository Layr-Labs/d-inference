package protocol

// Telemetry wire types — shared between coordinator, providers, the macOS app,
// and the console UI. All three implementations (Go, Rust, TypeScript) must
// agree on these JSON shapes.
//
// Design rules:
//   - No prompt/response content is ever put in telemetry. Ever.
//   - Field names are snake_case.
//   - Unknown enum values are coerced to "custom" server-side (forward-compat).
//   - Batches are capped server-side at 100 events / 64KB.

import "time"

// TelemetrySource identifies the component that produced a telemetry event.
type TelemetrySource string

const (
	TelemetrySourceCoordinator TelemetrySource = "coordinator"
	TelemetrySourceProvider    TelemetrySource = "provider"
	TelemetrySourceApp         TelemetrySource = "app"
	TelemetrySourceConsole     TelemetrySource = "console"
	TelemetrySourceBridge      TelemetrySource = "bridge"
)

// TelemetrySeverity is the severity level, modeled after syslog/RFC 5424 but
// narrowed to the set we actually emit.
type TelemetrySeverity string

const (
	SeverityDebug TelemetrySeverity = "debug"
	SeverityInfo  TelemetrySeverity = "info"
	SeverityWarn  TelemetrySeverity = "warn"
	SeverityError TelemetrySeverity = "error"
	SeverityFatal TelemetrySeverity = "fatal"
)

// TelemetryKind is a coarse categorization used for filtering and grouping
// in the admin UI. New kinds should be added here and mirrored in Rust/TS.
type TelemetryKind string

const (
	KindPanic              TelemetryKind = "panic"
	KindHTTPError          TelemetryKind = "http_error"
	KindProtocolError      TelemetryKind = "protocol_error"
	KindBackendCrash       TelemetryKind = "backend_crash"
	KindAttestationFailure TelemetryKind = "attestation_failure"
	KindInferenceError     TelemetryKind = "inference_error"
	KindRuntimeMismatch    TelemetryKind = "runtime_mismatch"
	KindConnectivity       TelemetryKind = "connectivity"
	KindLog                TelemetryKind = "log"
	KindCustom             TelemetryKind = "custom"
)

// TelemetrySourceCustom is returned when a source value can't be classified
// into a known bucket but we still want to keep the event.
const TelemetrySourceCustomValue TelemetrySource = "custom"

// TelemetrySourceCustom returns the fallback source used when an incoming
// value isn't in KnownSources.
func TelemetrySourceCustom() TelemetrySource { return TelemetrySourceCustomValue }

// KnownSources returns the set of supported source values for validation.
func KnownSources() map[TelemetrySource]struct{} {
	return map[TelemetrySource]struct{}{
		TelemetrySourceCoordinator: {},
		TelemetrySourceProvider:    {},
		TelemetrySourceApp:         {},
		TelemetrySourceConsole:     {},
		TelemetrySourceBridge:      {},
	}
}

// KnownSeverities returns the set of supported severity values for validation.
func KnownSeverities() map[TelemetrySeverity]struct{} {
	return map[TelemetrySeverity]struct{}{
		SeverityDebug: {},
		SeverityInfo:  {},
		SeverityWarn:  {},
		SeverityError: {},
		SeverityFatal: {},
	}
}

// KnownKinds returns the set of supported kind values for validation.
func KnownKinds() map[TelemetryKind]struct{} {
	return map[TelemetryKind]struct{}{
		KindPanic:              {},
		KindHTTPError:          {},
		KindProtocolError:      {},
		KindBackendCrash:       {},
		KindAttestationFailure: {},
		KindInferenceError:     {},
		KindRuntimeMismatch:    {},
		KindConnectivity:       {},
		KindLog:                {},
		KindCustom:             {},
	}
}

// TelemetryEvent is a single telemetry record.
//
// Fields that are optional client-side may be populated by the coordinator
// after ingestion (e.g. AccountID is enforced from the authenticated token).
type TelemetryEvent struct {
	ID        string            `json:"id"`                   // UUIDv4, provided by client
	Timestamp time.Time         `json:"timestamp"`            // client-side wall clock
	Source    TelemetrySource   `json:"source"`               // who produced this event
	Severity  TelemetrySeverity `json:"severity"`             // debug/info/warn/error/fatal
	Kind      TelemetryKind     `json:"kind"`                 // coarse categorization
	Version   string            `json:"version,omitempty"`    // component version (e.g. "0.3.10")
	MachineID string            `json:"machine_id,omitempty"` // stable per-machine identifier
	AccountID string            `json:"account_id,omitempty"` // server-stamped from auth
	RequestID string            `json:"request_id,omitempty"` // correlation with an inference job
	SessionID string            `json:"session_id,omitempty"` // per-process UUID, groups events from one boot
	Message   string            `json:"message"`              // developer-authored human string
	Fields    map[string]any    `json:"fields,omitempty"`     // allowlisted structured fields
	Stack     string            `json:"stack,omitempty"`      // backtrace / formatted stack
}

// TelemetryBatch is the wire payload for ingestion.
type TelemetryBatch struct {
	Events []TelemetryEvent `json:"events"`
}

// TelemetryFilter narrows read queries.
type TelemetryFilter struct {
	Source    TelemetrySource
	Severity  TelemetrySeverity
	Kind      TelemetryKind
	MachineID string
	AccountID string
	RequestID string
	Since     time.Time
	Until     time.Time
	Limit     int
}
