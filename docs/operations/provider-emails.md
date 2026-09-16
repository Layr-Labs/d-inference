# Provider email campaigns

> Last updated: 2026-09-16 · commit `00bf87be3`

Use `provider-emails` to preview provider-owner audiences, sync them to Resend,
and create an unsent update notice. Operators edit, review and send the notice
in Resend. Delivery history, bounce suppression and unsubscribe handling stay
in Resend; provider status stays in Darkbloom.

## When to use

Use for a provider software update, a supported macOS update, or an announcement
to active provider owners. The tool does not change version floors, routing,
account permissions, or the read-only admin dashboard. It does not install a
scheduler or send automatic reminders.

## Prerequisites

- Build the command using the repository Go toolchain:

  ```bash
  go build -o /tmp/provider-emails ./coordinator/cmd/provider-emails
  ```

- Provide `PROVIDER_EMAIL_DATABASE_URL` through your local secret manager or
  environment. Use a read-only database role or the read replica with `SELECT`
  on `users`, `providers`, `darkbloom_machines`, and
  `darkbloom_machine_sessions`. `ReadSnapshot` in
  `coordinator/provideremail/postgres.go` sets read-only mode and timeouts; it
  never constructs the migrating coordinator store. The existing machine
  inventory schema must already be present.
- Provide `RESEND_API_KEY` for sync, draft and live tests. Contacts, segments
  and broadcasts require a Full access key; a sending-only key is insufficient.
  Keep credentials outside tracked files. The command only uses the official
  Resend HTTPS API and refuses redirects.
- Verify the sender domain in Resend and use a monitored reply-to mailbox.
  Broadcasts use Resend's contact-based marketing plan and unsubscribe model;
  transactional email quota alone is not a broadcast entitlement.
- Obtain authorization for the particular provider campaign before sending.
  A “required” label does not override a recipient's unsubscribe or suppression.
  Review the exact operational message and Resend sending rules; critical
  requirements also need a console/provider notification channel.

## Steps

1. Copy an example to a private working directory and edit it.

   ```bash
   cp coordinator/provideremail/examples/provider-update.json /tmp/provider-campaign.json
   ```

   The other example is `coordinator/provideremail/examples/macos-update.json`.
   Both are examples, not approval to publish a version requirement. Choose a
   unique `id`, the qualified `minimum_version`, a useful subject and body, a
   monitored `reply_to`, and an HTTPS `instructions_url` with the update steps.
   Use `audience: "all"` without a minimum version for a general announcement.
   `severity` is `recommended` or `required`; required notices need a
   `deadline` in `YYYY-MM-DD` form. Explain any actual deadline consequence in
   the body. The tool does not enforce that consequence.

2. Preview the audience and rendered email without accessing Resend.

   ```bash
   /tmp/provider-emails preview -config /tmp/provider-campaign.json \
     -report /tmp/provider-audience.json -html /tmp/provider-notice.html
   ```

   Stdout contains counts only. The optional report contains email addresses,
   account IDs and affected-machine counts. New report/HTML files are created
   with mode `0600`; existing files and symlinks are refused. Keep reports out
   of Git and shared logs. Review excluded/unknown counts before proceeding.

3. Send a test only to your own explicit address.

   ```bash
   /tmp/provider-emails test -config /tmp/provider-campaign.json \
     -to operator@example.com -apply
   ```

   Without `-apply`, this only validates/renders. A live test is marked `[TEST]`,
   has a test-only banner, and does not load the fleet or create contacts. Each
   invocation has a new idempotency key; retries within it reuse that key. If a
   send times out, check Resend before invoking it again.

4. Preview the Resend membership changes, then apply them and create the draft.

   ```bash
   /tmp/provider-emails draft -config /tmp/provider-campaign.json
   /tmp/provider-emails draft -config /tmp/provider-campaign.json -apply
   ```

   Each command reads fresh fleet data. `sync` performs the same membership
   reconciliation without creating a draft. The segment is named
   `darkbloom/providers/<id>/<policy-hash>`; changing the audience, target or
   freshness windows creates a different segment. Re-running the same command
   reuses the segment and matching unsent draft. The sender uploads only email
   addresses and segment membership, not machine IDs, serials, account IDs,
   attestation proofs or fleet snapshots.

5. Open [Resend Broadcasts](https://resend.com/broadcasts), select the returned
   draft and review the content and recipients. Send after campaign approval.

   Use one operator at a time. Do not send, schedule, edit segment membership,
   or run a second sync while reconciliation is in progress. A sync rejects a
   segment referenced by a scheduled/sending or unknown-status broadcast. The
   API cannot make fleet selection, segment changes and a dashboard send
   atomic. Sync immediately before review/send; do not schedule a stale
   audience days ahead. A failed sync may leave partial membership, and the
   command refuses to create a new draft after failure. Repair by rerunning
   sync before sending any existing draft.

## Verification

`BuildAudience` in `coordinator/provideremail/audience.go` and `ReadSnapshot`
in `coordinator/provideremail/postgres.go` define selection:

- Take the newest registration per canonical inventory machine before applying
  ownership or activity filters. A delayed heartbeat on an old registration
  cannot select its previous owner. Merged identities resolve to the surviving
  machine. Inventory identities can be provisional or key-bound; these counts
  are not proof of distinct physical Macs.
- Include only authenticated `live_registration` observations with an account
  and a valid stored owner email, last seen within `active_within_days` (default
  30). Historical backfill, missing owner/email and inactive records are counted
  separately. Recently seen legacy provider sessions absent from inventory are
  reported as `untracked_sessions`, not silently attributed to an owner.
- Compare provider versions semantically, including prereleases. macOS versions
  must be numeric, have a known observation source, and be observed within
  `os_max_age_days` (default 7). Missing, malformed, future or stale OS evidence
  is unknown. Registration and App Attest status are reported OS information;
  this tool does not turn them into Apple-certified OS evidence.
- Send one broadcast copy per normalized email address, even for several
  machines/accounts sharing it. Existing subscription and topic preferences
  are never patched. Resend may further suppress unsubscribed, bounced or
  complained addresses; recipient count is not delivery count.

Check the Resend email log and the test inbox separately. For campaigns,
inspect delivery/bounce status in Resend. To measure progress, rerun `preview`
with the same policy: `at_target`, `needs_update` and `unknown_version` are
current machine observations within that window, not email opens or clicks.
They are not a frozen original-cohort conversion rate. The current email comes
from `users.email`; missing/stale account contacts require account remediation.

For a reminder, first preview/sync the remaining outdated audience. Use a new
campaign ID or changed message for a new draft after the first was sent. The
command never sends a reminder itself. Delete obsolete managed segments only
after checking that no draft or scheduled broadcast still references them.

## Rollback

Stop invoking the operator command. Nothing is installed in the coordinator
or scheduled automatically. Cancel any scheduled broadcast in Resend before
changing its audience. Remove unsent test drafts/segments through Resend if
needed; sent mail cannot be recalled. Revoke a temporary API key when testing
finishes. Do not delete contacts or reset subscription preferences to roll back
an audience sync.

## Related

- [Build](../developer/build.md) and [test](../developer/test.md).
- [Provider release](provider-release.md) and [provider installation](../provider/installation.md).
- [Resend contacts and broadcasts](https://resend.com/docs/dashboard/broadcasts/introduction).
