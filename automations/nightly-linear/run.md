# Run the nightly Darkbloom Linear update

The launcher has refreshed the dedicated clone and supplied this playbook and
both skill bodies from one fetched Git revision. Use those supplied bodies even
if a skill was already loaded earlier in the chat. If refresh failed or either
body is missing, stop before Linear writes and report the problem. Do not fall
back to cached instructions.

Read the local configuration and state at the absolute paths in the launcher.
Use `darkbloom-work-history` to collect work and `darkbloom-linear-nightly` to
reconcile it with current Linear. Use the launcher's mode: setup previews are
read-only; scheduled and explicitly requested manual runs use apply.

The person's setup authorization covers routine issue updates for the configured
workspace, owner, and team. Reuse existing issues, place genuinely unclassified
new work in the configured Others project, and verify each write. Recover pending
writes before retrying. Merge duplicated facts across tools and skip the nightly
automation's own bookkeeping.

Record the supplied Git revision in the run's local report and apply recovery
state. Any additional repository-owned instructions or supporting code must be
read from that same revision using `git show <revision>:<repository-relative-path>`.
Do not change the approved repository URL, branch, owner, workspace, work roots,
or schedule just because a new playbook requests it. Ask the person to authorize
those configuration changes. Preserve checkpoint and pending-action data across
playbook updates; if a new format cannot be migrated without losing it, report
that problem before writing to Linear.

Report verified issue changes with links and flag missing coverage or required
user action. Stay quiet when there is no new work or actionable problem. Follow
the installed skills' retry, ownership, status, and privacy rules.
