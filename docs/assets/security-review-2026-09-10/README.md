# Security review evidence

> Last updated: 2026-09-10 · commit `bd00919a0`

Evidence supporting the [September 10 security review](../../reports/2026-09-10-security-model-review.md). All accounts, payments and failures in the added probes are synthetic. A passing review probe confirms the stated unsafe behavior or protocol limit; it does not establish security.

## Reproduce the six probes

Use a disposable checkout of `bd00919a0b6a9354495dc9c90b28656bcf52d73d` with the repository's Go toolchain. The probe files are stored as `.txt` evidence so this documentation PR does not add tests that assert vulnerable behavior to the normal test suite. From the repository root:

```sh
cp docs/assets/security-review-2026-09-10/api_review_0910_test.go.txt coordinator/api/review_0910_test.go
cp docs/assets/security-review-2026-09-10/registry_review_0910_test.go.txt coordinator/registry/review_0910_test.go
go test -race ./coordinator/api ./coordinator/registry -run '^TestReview0910' -v -count=1
```

If checking out the baseline separately, copy the two evidence files from this PR into that baseline checkout. Convert these assertions to the desired safe contract when implementing fixes. Payment probes use the real handlers with an in-memory store; they do not simulate a real Postgres crash or call a payment processor. The replay probe isolates middleware and does not bypass authentication or demonstrate duplicate billing.

## Reproduce the reviewer audit

The [offline audit source](audit_review.py.txt) uses Python 3 and PyYAML. It extracts the pure diff-selection functions from the actual reviewer script without running its API client or making external requests:

```sh
python3 docs/assets/security-review-2026-09-10/audit_review.py.txt .
```

Its output includes a mechanical path-mapping inventory. Unmapped file counts are not a percentage of the codebase that is unsafe. The audit deliberately asserts the observed coverage omissions; a fix changes those expectations.

## Evidence interpretation

The [latest combined probe log](latest-review-probes.log.txt) covers all six probes with race detection. The [latest model audit](latest-model-audit.json) captures schema and coverage findings. Other logs preserve the earlier individual probes and broader Go baseline cited in the report. Local temporary linker paths have been replaced with `<temporary-linker-path>`; test results are unchanged.

The full baseline command was:

```sh
go test ./coordinator/attestation ./coordinator/apns ./coordinator/mdm \
  ./coordinator/auth ./coordinator/billing ./coordinator/payments/... \
  ./coordinator/mediafetch ./coordinator/internal/e2e \
  ./coordinator/registry ./coordinator/api
```

The focused security selection was:

```sh
go test ./coordinator/api \
  -run 'Test(Review0910|Security_|Device|CodeIdentity|CodeContinuity|RestartFreshProcessKey|RestartSameBinary|TrustReuse|ReleasePolicy|TokenlessProvider|ReleaseKey|MDMWebhook|SelfRoute)' \
  -count=1 -timeout=150s
```

Earlier focused and broad runs predate some added probes. The latest six-probe race run supplies their combined evidence. Live configuration, browser, native hardware and Postgres failure qualification remain outstanding. The documentation-check log records the earlier baseline; PR documentation validation is reported separately in the PR description.
