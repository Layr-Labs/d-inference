# Open Sales Program

> Last updated: 2026-09-07 · commit `14ffb2114`

Status: **In progress** — 2026-09-07 — implementation and verification prepared for pull-request review; not deployed.

Give the person who refers a Darkbloom consumer a recurring reward on that
consumer's collected inference spend. This record defines the product and
accounting contract; the as-built mechanism belongs in
[Billing](../architecture/billing.md#consumer-referral).

## Decision

“Token volume” means the amount actually charged for token usage in micro-USD,
not the raw token count or a share of the platform fee. Reward each eligible
request at 5%, rounded down to a whole micro-USD. Darkbloom funds this additive
reward: consumer prices, provider payouts, and platform-fee credits are
unchanged. Earnings enter the existing withdrawable balance and use existing
withdrawal eligibility and payment rails.

Keep one code per referrer account and one immutable referrer per consumer
account. Reject self-referral and reassignment; applying the same code again
succeeds without another relationship. Attribution is prospective and has no
expiry. No reward is due for already-settled usage, free self-route, refunded
reservations, or charges that were not collected. Existing relationships
participate in future settlements; do not backfill earlier rewards.

## Implementation plan

1. Persist consumer settlement and its referral reward atomically, keyed by
   request ID. Return the recorded settlement on replay instead of charging or
   crediting again. Preserve reservation refunds, overage clamps, and service
   holds before calculating eligible spend.
2. Make the reward rate a fixed constant. Retire the former platform-fee share
   configuration so an inherited environment value cannot alter this program.
3. Keep account-scoped register/apply/info/stats APIs. Return an empty
   info response for an account without a referral code (stats stays 404), expose the spend basis,
   and separate lifetime rewards from available earned balance.
4. Add a console Open Sales Program page for code registration, a copyable share link,
   attribution, and earnings. Preserve the first valid `?ref=CODE` through
   sign-in, then apply it to the authenticated account.
5. Keep modules focused: settlement persistence, referral domain rules, HTTP
   handlers, browser attribution, data hooks, and presentation each have one
   responsibility.

## Verification checklist

- [x] Accounting: exact rate and rounding, input validation and zero exclusion, collected
      overage clamp, refund, direct debit and service-hold paths.
- [x] Persistence: memory/Postgres parity, atomic rollback, concurrent/repeated
      settlement, one reward per request, attribution timing and immutability.
- [x] API: authenticated account scoping, empty info and unregistered stats, normalized code,
      self-referral, same-code replay, conflicting code and store errors.
- [x] Console: registration, copying, application, earnings, errors, loading,
      first-touch persistence, sign-in and retry states, account isolation.
- [x] Review: focused tests, full relevant Go/UI suites, lint/build, browser
      verification, docs-check, behavior-preserving modularity pass, PR description with
      before-and-after behavior and code diagrams.

## Rollout boundary

The deliverable is reviewed code and an open pull request. Production deployment
and any live payout or configuration change remain separate human-approved
operations. Reconcile the new settlement records with referral ledger entries
when verifying a later rollout; a page rendering successfully alone is not
proof that money was settled.
