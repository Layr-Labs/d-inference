# Provider owner email notifications

The coordinator can email a provider owner when a linked Mac stops earning or is
blocked from routing.

## Enable

Set these coordinator environment variables:

```bash
EIGENINFERENCE_RESEND_API_KEY=...
EIGENINFERENCE_EMAIL_FROM='Darkbloom <providers@darkbloom.dev>'
EIGENINFERENCE_CONSOLE_URL=https://console.darkbloom.dev
```

Optional tuning:

```bash
EIGENINFERENCE_PROVIDER_ALERT_CHECK_SECONDS=300
EIGENINFERENCE_PROVIDER_ALERT_COOLDOWN_HOURS=24
EIGENINFERENCE_EMAIL_UNSUBSCRIBE_URL=https://darkbloom.dev/unsubscribe
```

Notifications are sent only to linked machines
(`ProviderRecord.AccountID -> User.Email`) and are rate-limited per
machine/reason in the store.

## Blocking reasons

- no heartbeat beyond the provider heartbeat timeout
- provider version below `EIGENINFERENCE_MIN_PROVIDER_VERSION`
- runtime hash/manifest verification failed
- attestation challenges failed or became stale
- trust below the coordinator minimum, usually MDM enrollment or hardware
  verification missing
- critical thermal state reported by the provider

## Deliverability checklist

Use a transactional sender and a Darkbloom-controlled subdomain, for example
`providers@darkbloom.dev` or `noreply@providers.darkbloom.dev`.

Before enabling production sends:

1. Verify the sending domain in Resend.
2. Publish the provider's DKIM records exactly as shown by Resend.
3. Publish/confirm SPF for the sending domain.
4. Publish DMARC on the organizational domain, starting with monitoring:
   `v=DMARC1; p=none; rua=mailto:dmarc@darkbloom.dev`, then tighten to
   `quarantine`/`reject` after reports are clean.
5. Use the configured Darkbloom `From` address consistently.
6. Keep alerts transactional and low-volume; the coordinator enforces a
   per-machine/per-reason cooldown.
