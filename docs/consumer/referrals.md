# Open Sales Program: share a code and withdraw rewards

> Last updated: 2026-09-07 · commit `14ffb2114`

Use the Open Sales Program to refer consumers to Darkbloom, track their contribution to
your referral earnings, and withdraw earned rewards. The reward is a share of
collected inference spend; the exact rate, units, and rounding are in
[pricing formulas](../reference/pricing-model.md#formulas).

## Prerequisites

- A Darkbloom account signed into the console.
- For withdrawals, meet the payout requirements in
  [Billing — withdraw earned balance](billing.md#9-withdraw-international-earnings).
  Creating a referral code does not require running a provider.

## Steps

1. Visit **Open Sales Program** in the console and register your code. Use a short,
   recognizable code following the
   [code rules](../reference/pricing-model.md#constants). Your account keeps
   one code; registering again returns that code.
2. Copy the referral link and share it with the consumer you are referring.
   The `?ref=CODE` link saves the first code with a valid format in that browser through
   sign-in. The console applies it after authentication. The saved code stays until
   application succeeds or you select **Remove saved code**; later links do
   not replace it.
3. Ask the consumer to check **Open Sales Program** before starting paid usage. They can
   also enter a code there directly. Applying the same code again is safe;
   accounts cannot refer themselves or replace an existing referrer. Attribution
   has no expiry.
4. Return to **Open Sales Program** to inspect the referred-consumer count, eligible
   token spend, and lifetime rewards. Only usage settled with an attached referrer qualifies.
   Free requests, refunded reservations, and money that was not collected do
   not generate rewards. Rewards are funded by Darkbloom and do not change the
   consumer's price or the serving provider's earnings. Spent invite and admin
   credits also qualify because they use the same spendable balance.
5. Open **Billing** to withdraw your available earned balance using the
   [withdrawal steps](billing.md#9-withdraw-international-earnings). Referral rewards
   join other earnings in the same balance. Lifetime rewards stay visible even
   after you spend or withdraw them.

### Use the API

Register and apply use a Privy access token; the actions act on the signed-in
account. Replace the placeholder token in these commands.

```bash
curl -X POST https://api.darkbloom.dev/v1/referral/register \
  -H 'Authorization: Bearer <privy-access-token>' \
  -H 'Content-Type: application/json' \
  -d '{"code":"MYCODE"}'
```

The referred consumer applies the code with their own token:

```bash
curl -X POST https://api.darkbloom.dev/v1/referral/apply \
  -H 'Authorization: Bearer <consumer-privy-access-token>' \
  -H 'Content-Type: application/json' \
  -d '{"code":"MYCODE"}'
```

Read your own dashboard with `GET /v1/referral/info` and
`GET /v1/referral/stats`. Info works before registration; stats returns 404
until you register a code. The complete
[referral API contract](../reference/api-contracts.md#open-sales-program-payloads)
describes the response fields. Deposits can also carry `referral_code`;
see [Billing](billing.md#6-referral-codes).

## Verify

- The consumer's **Open Sales Program** page shows the expected referrer code before
  they make the first eligible request.
- After an eligible request settles, the referrer's dashboard shows the
  collected spend and earned reward. The ledger contains a `referral_reward`
  entry tied to that request.
- Available earned balance can differ from lifetime referral earnings because
  it includes other earnings and reflects spending and withdrawals.

## Troubleshooting

| Symptom | Check | Action |
|---|---|---|
| Code is taken or invalid | Code ownership and [code rules](../reference/pricing-model.md#constants) | Choose another code when registering; check spelling when applying. |
| Account already has a referrer | The code shown in Open Sales Program | Keep the existing attribution; it cannot be reassigned. |
| Cannot refer yourself | You opened your own share link | Share the link with another consumer account. |
| No reward after a deposit | Deposits fund usage; they are not usage | Check again after eligible paid inference settles. |
| No reward for an earlier request | Attribution time and actual collected cost | Already-settled requests are not backfilled; free and uncollected usage do not qualify. |
| Referral link did not attach | Sign-in and existing attribution | Finish sign-in, then check Open Sales Program and apply the code there if needed. |
| Wrong saved link | The pending code in Open Sales Program | Select **Remove saved code**, then enter the intended code before it is applied. |
| Reward below a whole micro-USD | [Rounding rule](../reference/pricing-model.md#formulas) | Such a request contributes eligible spend but no positive reward credit. |
| Withdrawal unavailable | Available earned balance and payout setup | Follow [Billing](billing.md); deposited credits are not withdrawable. |

## Related

- [Billing](billing.md) — balances, deposits, and withdrawals.
- [Referral accounting](../architecture/billing.md#consumer-referral) — settlement and attribution invariants.
- [Pricing reference](../reference/pricing-model.md) — reward rate and arithmetic.
- [API contracts](../reference/api-contracts.md#open-sales-program-payloads) — account-scoped payloads and errors.
