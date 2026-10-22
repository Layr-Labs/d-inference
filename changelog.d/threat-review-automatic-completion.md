### Automatic threat-review completion and human handoff

CI sizes native review allowances from source batches, selected independent depth
and cross-file integration rounds, retaining one shared response repair and an
emergency ceiling. Generous native defaults allow up to 500 calls and 16,384
output tokens per call with ten minutes per native response. Maintainers can
lower the call and output limits through Actions variables. A longer bounded
scan deadline leaves time to save findings
and publish a human-review handoff when the scan cannot complete.

Normal reviews send critical source directly to Sol instead of repeating it with
Opus first. All source still receives Sonnet review and cross-file integration;
clean tests/docs avoid filename-only depth, and integration findings target their
cited batches. Global uncertainty requires human review without a blanket rescan.
Production attestation filenames are not mistaken for Swift test suffixes;
critical source outside explicit support trees takes precedence over filename hints.

Paid manual dispatches and GitHub job reruns are disabled. Incomplete reviews
explicitly require a human and cannot grant merge clearance. Advisory mode and
existing OpenRouter spending limits remain unchanged.
