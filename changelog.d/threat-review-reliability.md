### Threat review reliability

- Distinguish completed scans requiring human review from failed or incomplete
  scans. Preserve change context across source batches and reconcile Sol's local
  questions before its final decision, within existing spending limits.
- Add content-free failure diagnostics with validation codes, JSON positions,
  model/batch correlation and Bedrock request metadata. Raw responses, prompts,
  source text and credentials are excluded from diagnostic artifacts.
- Keep unresolved cross-file questions for human review and restrict each
  model's integration citations to its reviewed source. Preserve diagnostic
  progress across interruptions without allowing logging failures to hide reports.
