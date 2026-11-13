### Keep CI runners within their workflow run

Routed CI jobs use a workflow-run-specific runner label, preventing an older run's idle runner from taking a newer run's job. Invalid or unsupported scoped responses retain the existing fallback runner.
