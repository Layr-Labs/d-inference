### GLM-5.3-Flash serves OpenRouter's returned-reasoning tool requests

- Accept `strict` tool declarations on GLM-5.3-Flash instead of refusing the request with 400 `invalid_request`. GLM does not constrain decoding; every tool call is still validated against its declared schema before it is returned, so a non-conforming call fails the request.
- Render reasoning returned on earlier assistant turns as OpenRouter's `reasoning` string or `reasoning_details` text entries in the template's history, exactly like `reasoning_content`; summary and encrypted entries are skipped. Previously those turns rendered an empty thinking block.
- Read a returned tool call with empty-string `arguments` as a call without arguments (`{}`), as the other native families do.
- Treat `reasoning: null`, null `reasoning` members and `include_reasoning: null` as unset, accept `reasoning.summary` levels (the full reasoning is returned), and accept the top-level `thinking` switch as a Boolean or as GLM's own `{"type": "enabled"|"disabled", "clear_thinking": …}` object.
- Contradictory thinking switches, unknown `reasoning` members, `preserve_thinking`, forced tool choices and hidden reasoning (`reasoning.exclude: true`, `include_reasoning: false`) are still refused.
