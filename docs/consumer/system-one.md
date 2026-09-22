# Evaluate decisions with SystemOne

> Last updated: 2026-09-22 · commit `ce809b792`

Use `POST /v1/systemone` to evaluate choices, scores, and yes/no probabilities
with a native Laya model. It returns structured decisions without generating
text. This how-to applies once an operator has published and enabled a Laya
catalog build and a compatible provider is available.

## Prerequisites

- An API key permitted to use the selected model and a funded balance, or an
  owned provider with self-routing enabled.
- A model from `/v1/models` with `supported_features:["system_one"]` and
  `metadata.model_type:"laya"`. Use the returned model ID; the example assumes
  an operator has configured the alias `laya`.

## Steps

1. Send the state and a map of named questions. Choice criteria order is
   preserved in the model input.

   ```bash
   curl https://api.darkbloom.dev/v1/systemone \
     -H "Authorization: Bearer $DARKBLOOM_API_KEY" \
     -H 'Content-Type: application/json' \
     -d '{
       "model": "laya",
       "state": "The customer has been unable to log in for three days.",
       "questions": {
         "department": {
           "type": "choice",
           "instructions": "Which team should handle this?",
           "criteria": {"support": "Account access", "billing": "Payments"}
         },
         "urgency": {"type": "noul", "instructions": "Does this need urgent attention?"},
         "priority": {
           "type": "score",
           "instructions": "Rate the urgency",
           "criteria": ["Low", "Medium", "High"]
         }
       }
     }'
   ```

2. Read each result under `answers.<question-id>`. `choice` provides a selected
   option and probabilities. `score` provides a probability-weighted level and
   legend. `noul` provides a probability between 0 and 1. Each includes a
   confidence and `action.act_probability` from Laya's trained decision heads.

3. Read `usage.input_tokens` for the sum of encoded tokens across question
   rows. `usage.output_tokens` is zero. Each question has a 512-token encoder
   budget; the runtime truncates the state to fit after its question and
   criteria. Question text uses the checkpoint's header truncation rules,
   including truncation of the instruction prefix and option descriptions.
   Requests whose option header still cannot fit are rejected. Keep state,
   instructions, and options concise. There are at most 64 questions per
   request. The plaintext JSON body is limited to 1 MiB.

## Verify

A successful request returns HTTP 200 with `model`, `answers`, and `usage`.
The `model` value echoes your requested ID or alias. There is no chat `choices`
envelope or streaming response. Authenticated transport, per-key model limits,
rate limiting, and [verification](verification.md) use the existing inference
path. See [billing](billing.md) for account charging and the
[API contract](../reference/api-contracts.md#systemone-decisions) for fields.

## Troubleshooting

| Status | Action |
|---|---|
| 401 | Check the bearer key |
| 402 | Add balance or use an owned provider with self-routing |
| 422 | Use the native endpoint, valid typed questions, and no generation controls; shorten instructions and criteria if the provider rejects their encoder length |
| 429 | Honor `Retry-After`; rate, capacity, or coordinator-drain admission rejected the request |
| 503 | Check that a compatible native provider and catalog build are available |

## Related

- [Models and aliases](models.md)
- [HTTP contract](../reference/api-contracts.md#systemone-decisions)
- [Privacy expectations](privacy-expectations.md)
