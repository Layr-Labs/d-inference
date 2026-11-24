### An earlier tool call's null arguments reach the model as null

A JSON `null` in an earlier assistant tool call's arguments (for example
`{"deadline": null}`) was dropped before the chat template rendered, because
the template engine cannot take a null value. The model was shown a different
call, such as Gemma 4's `call:clear_project_deadline{}`, and asked to repeat it
returned the wrong arguments: a missing required property, or a refusal when
the tool was strict. These nulls now render as `null` at the key or array
position the call had them: Gemma 4's argument macro and the Qwen 3.5 and
Nemotron 3.5 Lightning parameter value gain a `null` branch, and the templates
that write arguments as JSON (Qwen 3.6, Qwen 3.8, GPT-OSS, Inkling 2) print it
as they already did. GLM-5.3, MiMo, Flint and Nemotron 3.5 Super already kept
these nulls and render as before. Nulls elsewhere in a message and in tool
parameter schemas are still omitted.

The prompt contract stays `darkbloom-request-normalization-v9`, which still
renders these calls without their nulls, so a coordinator request whose
tool-call history carries such a null is served without the prompt cache: no
cache lookup, receipt or checkpoint write, and no cached-token usage. Every
other request is unchanged. `darkbloom logs` notes each such request, and the
daemon state counts them (`promptCacheSkippedToolCallNull`).
