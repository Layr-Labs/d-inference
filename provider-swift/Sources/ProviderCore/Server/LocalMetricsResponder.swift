// Copyright © 2026 Eigen Labs.
//
// Provider-local MTP observability on the local `/metrics` endpoint.
//
// WHY THIS EXISTS: the MTP acceptance/proposed/accepted counters live in the
// engine (`CBv2MTPMetrics`, polled via `EngineV2Bridge.mtpStatusSnapshot()`)
// and until now surfaced ONLY through the `engine_v2_slot_posture` telemetry
// event — i.e. Datadog Logs. A headless operator (sandboxes have no os_log
// store access) had no way to observe whether MTP is producing drafts, what
// the acceptance ratio is, or that MTP silently never activated (e.g.
// `inline_artifact_invalid` on a symlinked HF snapshot). `/metrics` is the
// provider-local operator surface, so the posture trio the daemon state and
// telemetry already agreed on (`mtp_enabled` / `mtp_active` /
// `mtp_inactive_reason`) plus the cumulative counters are appended here.
//
// The upstream `/metrics` handler lives in `MLXLMServer`
// (`ServerMetrics.prometheusText()`), whose router is already built when the
// provider wraps it — the same reason `LocalChatUploadResponder` exists. This
// responder therefore serves GET `/metrics` itself: the upstream body (same
// public `MLXOpenAIService.prometheusMetrics()` entry point the upstream
// handler calls) plus the provider-owned MTP lines, in the same Prometheus
// text style. Everything else forwards to the wrapped router unchanged.
//
// Deliberately NOT touched: the coordinator telemetry wire types. Those are
// mirrored in Go/Swift/TS and adding fields there is a three-language sync;
// `/metrics` is provider-local and free to carry the full posture.

import Foundation
import Hummingbird
import MLXLMServer
import NIOCore

/// One slot's MTP posture sample for the local `/metrics` endpoint —
/// `EngineV2Bridge.mtpStatusSnapshot()` keyed by the registry's model id,
/// the same pairing `DaemonSlotPostureBuilder.LiveSlot` uses.
public struct MTPSlotMetricsSample: Sendable {
    let model: String
    let snapshot: ProviderMTPStatusSnapshot

    init(model: String, snapshot: ProviderMTPStatusSnapshot) {
        self.model = model
        self.snapshot = snapshot
    }
}

/// Renders the provider-owned MTP lines appended to the upstream
/// `ServerMetrics.prometheusText()` body, following its `# TYPE` + bare-line
/// convention. Counters are CUMULATIVE per slot lifetime — the standard
/// counter contract, matching the slot-posture telemetry event — so any
/// scraper can difference two samples; the acceptance ratio is
/// `mtp_tokens_accepted_total / mtp_tokens_proposed_total`.
enum MTPPrometheusRenderer {
    static func render(_ slots: [MTPSlotMetricsSample]) -> String {
        guard !slots.isEmpty else { return "" }
        var out = ""
        // One `# TYPE` header per family with every slot's sample beneath it,
        // as the Prometheus text format requires.
        func family(
            _ name: String, _ type: String,
            _ sample: (MTPSlotMetricsSample) -> String?
        ) {
            let lines = slots.compactMap(sample)
            guard !lines.isEmpty else { return }
            out += "# TYPE \(name) \(type)\n"
            for line in lines { out += line + "\n" }
        }
        func label(_ sample: MTPSlotMetricsSample) -> String {
            "model=\"\(escapeLabel(sample.model))\""
        }
        family("mtp_enabled", "gauge") {
            "mtp_enabled{\(label($0))} \($0.snapshot.configured ? 1 : 0)"
        }
        family("mtp_active", "gauge") {
            "mtp_active{\(label($0))} \($0.snapshot.active ? 1 : 0)"
        }
        family("mtp_rounds_total", "counter") {
            "mtp_rounds_total{\(label($0))} \($0.snapshot.rounds)"
        }
        family("mtp_tokens_proposed_total", "counter") {
            "mtp_tokens_proposed_total{\(label($0))} \($0.snapshot.proposedTokens)"
        }
        family("mtp_tokens_accepted_total", "counter") {
            "mtp_tokens_accepted_total{\(label($0))} \($0.snapshot.acceptedDraftTokens)"
        }
        // Present whenever MTP is not PRODUCTIVELY running — the same
        // omitted-when-healthy contract as the telemetry field, and the line
        // that makes a silently-disabled drafter (`inline_artifact_invalid`,
        // `inert_kv_unsupported`, …) operationally visible.
        family("mtp_inactive_reason", "gauge") { sample in
            guard let reason = sample.snapshot.fallbackReason?.rawValue else { return nil }
            return "mtp_inactive_reason{\(label(sample)),reason=\"\(escapeLabel(reason))\"} 1"
        }
        return out
    }

    /// Prometheus text-format label escaping: backslash, quote, newline.
    static func escapeLabel(_ value: String) -> String {
        var escaped = ""
        escaped.reserveCapacity(value.utf8.count)
        for character in value {
            switch character {
            case "\\": escaped += "\\\\"
            case "\"": escaped += "\\\""
            case "\n": escaped += "\\n"
            default: escaped.append(character)
            }
        }
        return escaped
    }
}

/// Serves GET `/metrics` itself (upstream body + MTP posture lines) and
/// forwards every other request to the wrapped upstream router. Sits INSIDE
/// `CORSResponder` so its response carries the CORS header, exactly like
/// `LocalChatUploadResponder`.
public struct LocalMetricsResponder<Inner: HTTPResponder>: HTTPResponder
where Inner.Context == BasicRequestContext {
    public typealias Context = BasicRequestContext

    public let inner: Inner
    let service: MLXOpenAIService
    let mtpSlots: @Sendable () async -> [MTPSlotMetricsSample]

    init(
        inner: Inner,
        service: MLXOpenAIService,
        mtpSlots: @escaping @Sendable () async -> [MTPSlotMetricsSample]
    ) {
        self.inner = inner
        self.service = service
        self.mtpSlots = mtpSlots
    }

    public func respond(to request: Request, context: Context) async throws -> Response {
        guard request.method == .get, request.uri.path == "/metrics" else {
            return try await inner.respond(to: request, context: context)
        }
        let body = await service.prometheusMetrics()
            + MTPPrometheusRenderer.render(await mtpSlots())
        return Response(
            status: .ok,
            headers: [.contentType: "text/plain; charset=utf-8"],
            body: .init(byteBuffer: ByteBuffer(string: body)))
    }
}
