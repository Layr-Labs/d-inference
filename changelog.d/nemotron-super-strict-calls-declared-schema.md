### Nemotron 3.5 Super checks strict tool calls against the declaration as sent

- A `strict` `auto` tool call from Nemotron 3.5 Super is now checked against
  the tool declarations as the client sent them, the same ones its call
  grammar holds values to. Before, its validator read the declarations after
  ingress normalization had written `type: "string"` into properties without
  a type, and refused with 422 `tool_noncompliance` (`schema`) a call the
  grammar had admitted, such as a number for a nested property that declares
  no type.
- The change shows where the body reaches the provider as the client sent it
  (the Mac's own API). A body whose typeless properties were already given a
  type before it reached the provider is checked as before.
