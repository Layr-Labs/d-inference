import Foundation

/// The one builder for `kind: .engineHealth` telemetry, and the one sink
/// fallback in front of it.
///
/// Four call sites hand-rolled the same five-key base — `component`,
/// `operation`, `backend`, `kv_backend`, `model` — and three of them
/// re-implemented `if let sink { sink(event) } else { TelemetryClient.shared
/// .emit(event) }` beside it. `TelemetryFieldFilter` drops unmirrored keys
/// SILENTLY, so a base assembled by hand fails the way that is hardest to
/// notice: the producer looks healthy and the field never arrives.
///
/// `kvBackend` is OPTIONAL and must stay optional. Absent means the slot's
/// backend was never resolved, which is a different fact from any value the
/// vocabulary could carry — see `emitPrefixCacheConstructionFailure`, whose
/// whole point is that a construction failure before backend resolution omits
/// the key rather than guessing. Defaulting it to a string would silently turn
/// "we do not know" into an observation at exactly one call site and nobody
/// would see it happen.
enum EngineHealthEvent {

    /// Every engine-health event names the ENGINE here. `backend` is the
    /// engine executing inference (matching `RegisterMessage.backend` on the
    /// wire); `kv_backend` is the KV storage kind. Three axes, three keys —
    /// see docs/reference/telemetry-schema.md.
    static let engineBackend = "engine_v2"

    /// Build an `engine_health` event with the shared base plus `extra`.
    ///
    /// `extra` wins on a key collision so a call site can specialize, but
    /// nothing in the tree does today: the base keys mean the same thing
    /// everywhere, which is why they are shared at all.
    static func make(
        severity: TelemetrySeverity,
        message: String,
        operation: String,
        model: String,
        kvBackend: String?,
        extra: [String: AnyCodableValue] = [:]
    ) -> TelemetryEvent {
        var fields: [String: AnyCodableValue] = [
            "component": .string("engine"),
            "operation": .string(operation),
            "backend": .string(engineBackend),
            "model": .string(model),
        ]
        if let kvBackend {
            fields["kv_backend"] = .string(kvBackend)
        }
        for (key, value) in extra {
            fields[key] = value
        }
        var event = TelemetryEvent(
            source: .provider,
            severity: severity,
            kind: .engineHealth,
            message: message)
        event.fields = TelemetryFieldFilter.filter(fields)
        return event
    }
}

/// Route an event through the injectable sink (tests) or the shared client
/// (production). Free function so the static factories above and the
/// `EngineV2Bridge.emit(_:)` instance method share one rule; a call site that
/// re-implements it is a call site that can forget the fallback.
func emitEngineHealth(
    _ event: TelemetryEvent,
    sink: (@Sendable (TelemetryEvent) -> Void)?
) {
    if let sink {
        sink(event)
    } else {
        TelemetryClient.shared.emit(event)
    }
}
