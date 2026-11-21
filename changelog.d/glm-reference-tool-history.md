### GLM-5.3-Flash: history tool calls and tool schemas read as vLLM and the OpenAI API read them

- GLM-5.3-Flash refused a conversation with `invalid request` when an earlier
  tool call's arguments repeated a key, held a number no JSON value holds
  exactly (an integer beyond 64 bits, a decimal with more than 17 significant
  digits), or contained GLM tool-call markers as text. It refused a tool schema
  with such a number too, for example a 64-bit unsigned bound or a float64
  maximum. vLLM's GLM-5.3 serving and the OpenAI API accept all of these. Long
  tool-using conversations collected them, and every later turn of the
  conversation was then refused.
- These are now read as those servers read them:
  - a repeated key keeps its last value;
  - such a number is read as a JSON value holds it, so an integer beyond 64
    bits becomes its nearest double;
  - the markers are text.
- Arguments that are not one JSON object, and broken call and result pairing,
  are still refused.
- Requests that were already accepted render byte-identically.
- `DARKBLOOM_GLM_REFERENCE_TOOL_HISTORY=0` restores refusing them.
