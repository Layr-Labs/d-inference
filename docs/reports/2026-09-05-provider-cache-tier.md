# Provider cache tier advertisement check

> Last updated: 2026-09-05 · commit `e3f3fd160`

The provider now advertises resident prefix evidence only when its engine can
actually select that tier. An accepted complete SSD checkpoint store takes
precedence, including while its durable readiness capability is temporarily
absent. This is a prerequisite for coordinator service-cost scoring.

`EngineV2Bridge` suppresses both the resident evidence producer and its sequencer
when `EngineV2.completePrefixCache` is present. SSD remains the default and
resident storage still requires the existing explicit opt-in. An unused opt-in
bank may still be constructed and budgeted during preparation; removing that
construction requires a separate change to early budget and fallback handling.

The actual slot fixture constructs a tiny Qwen engine, requires acceptance of
the complete store, and explicitly enables a resident bank. It checks that the
bank exists and is charged while no resident wire producer exists, and retains
the unique durable-receipt lifecycle checks. Default and disabled-cache cases
remain covered for dense and MoE Qwen targets.

The focused provider run passed 40 test functions in four suites in 0.199 s,
with no skips. Those suites also cover Swift Jinja loops, Gemma arguments and
GPT-OSS Harmony. Build 6 passed after the separately developed native prefill
fence change; this was a shared integration build, not an isolated two-file
build. It establishes no full-size-model or latency result.

The [evidence manifest](evidence/2026-09-05-provider-cache-tier/manifest.json)
records the exact two source hashes, the complete build-source manifest and
the [test log](evidence/2026-09-05-provider-cache-tier/focused-prerequisites.log.gz).
