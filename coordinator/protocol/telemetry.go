package protocol

// Telemetry wire types — the canonical definitions, mirrored in Swift
// (provider-swift/Sources/ProviderCore/Telemetry/) and TypeScript
// (console-ui/src/lib/telemetry-types.ts). All three must agree on these JSON
// shapes; the symmetry tests pin them. The coordinator's own emitter
// (coordinator/telemetry) is the only live producer: the Swift and TypeScript
// client facades are inert and the coordinator has no ingestion route.
//
// Design rules:
//   - No prompt/response content is ever put in telemetry. Ever.
//   - Field names are snake_case.
//   - Event fields are the fixed operational keys each emitting call site
//     passes; nothing filters, coerces or re-stamps them afterwards.

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

// TelemetryKind is a coarse categorization; the emitter tags its metric and
// log with it. New kinds should be added here and mirrored in Swift/TS.
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
	// KindOOM: a provider-detected jetsam/crash-log OOM (surfaced next launch)
	// or a coordinator-classified oom_suspected disconnect.
	KindOOM TelemetryKind = "oom"
	// KindEngineHealth: provider engine-health diagnostics for the first-token
	// wedge (model-load milestones, periodic engine snapshots, wedge-suspected
	// transitions). NON-PRIVATE operational counters only.
	KindEngineHealth TelemetryKind = "engine_health"
	KindLog          TelemetryKind = "log"
	KindCustom       TelemetryKind = "custom"
)

// KnownKinds returns the closed kind set the symmetry tests pin.
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
		KindOOM:                {},
		KindEngineHealth:       {},
		KindLog:                {},
		KindCustom:             {},
	}
}

// TelemetryEvent is a single telemetry record.
type TelemetryEvent struct {
	ID        string            `json:"id"`                   // UUIDv4, minted by the producer
	Timestamp time.Time         `json:"timestamp"`            // producer wall clock
	Source    TelemetrySource   `json:"source"`               // who produced this event
	Severity  TelemetrySeverity `json:"severity"`             // debug/info/warn/error/fatal
	Kind      TelemetryKind     `json:"kind"`                 // coarse categorization
	Version   string            `json:"version,omitempty"`    // component version (e.g. "0.3.10")
	MachineID string            `json:"machine_id,omitempty"` // stable per-machine identifier
	AccountID string            `json:"account_id,omitempty"` // account the event concerns
	RequestID string            `json:"request_id,omitempty"` // correlation with an inference job
	SessionID string            `json:"session_id,omitempty"` // per-process UUID, groups events from one boot
	Message   string            `json:"message"`              // developer-authored human string
	Fields    map[string]any    `json:"fields,omitempty"`     // operational keys fixed by the call site
	Stack     string            `json:"stack,omitempty"`      // backtrace / formatted stack
}
