/// Which requests a pair served measure its speed: the speed records that
/// steer the next plan (the served race between modes, the request the plan is
/// made for, the rates served requests calibrate) and the per-request route.
/// A speed record completed, computed its whole prompt, had the pair to itself
/// (`ClusterPairRequestTelemetry.isSpeedRecord`, where the leader writes it) and
/// answered at least `minimumCompletionTokens`. A shorter answer is mostly its
/// first token, and its decode rate a handful of steps: every request
/// Darkbloom sends to check a pair asks for fewer tokens (the warm-up canary
/// 8, the onboarding's test answer 48), as did the readiness probes a pair was
/// checked with (16) and a short chat ("Say hi"); such probes kept a pipeline
/// decoding 39.6 tok/s over tensor parallel decoding 114.8 (2026-10-22). Every
/// reader of the records applies the rule again (`ClusterServedSample.fromTelemetry`),
/// so records an earlier build kept are read the same way.
public enum ClusterServedSpeedRule {
    public static let minimumCompletionTokens = 64
}
