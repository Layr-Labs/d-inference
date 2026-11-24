### An earlier tool call's null arguments reach the model as null

A JSON `null` in an earlier assistant tool call's arguments (for example
`{"deadline": null}`) and in a tool's parameter schema (an `enum` member, a
`const` or a `default`) was dropped before the chat template rendered, because
the template engine cannot take a null value. The model was shown a different
call, such as Gemma 4's `call:clear_project_deadline{}`, and asked to repeat
it returned the wrong arguments: a missing required property, or a refusal
when the tool was strict. These nulls now render as `null`: Gemma 4's argument
macro and the Qwen 3.5 / 3.6 and Nemotron 3.5 parameter value gain a `null`
branch, and the templates that write arguments as JSON (Qwen 3.8, GPT-OSS,
Inkling 2) print it as they already did. Nulls elsewhere in a message are still
omitted, and a request without such nulls renders byte for byte as before.
