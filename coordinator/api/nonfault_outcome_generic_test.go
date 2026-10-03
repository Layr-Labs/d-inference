package api

// PR #548 review round 3 (Codex P2): tool_noncompliance route rows must not be
// provider-failure outcomes. The outcome builders key on the SAME shared
// vocabulary as the reputation and breaker exemptions
// (isNonProviderFaultErrorReason), so the lists cannot drift.
