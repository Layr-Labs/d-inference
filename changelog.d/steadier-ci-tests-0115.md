### Steadier tests (CI only)

- Three tests that failed now and then on CI are less timing-sensitive and less exposed to other tests: the KV re-slice floor scenarios pin the GLM retained-memory charge (another test in the same process could leave one and shrink their budget), the sandbox setup reruns compare their report without its "last checked … ago" age, and the pair onboarding checks wait up to 30 s for a prompt. No provider change.
