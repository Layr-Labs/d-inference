### GPT-OSS tool arguments under a union are no longer held to its first branch

Under `tool_choice: "auto"`, GPT-OSS's call grammar compiled the type the
schema repair writes beside a union (`anyOf` / `oneOf` naming one of their
branches), a mixed `enum`, a `not` or an `if` as a hard type. A parameter
declared as `string` or `integer` could then only be written as a string
(`"-4200"` for `-4200`). The grammar now reads that type as the render hint
it is, as the call parser and the strict check already do, so each declared
branch is admitted. Declarations without such a type compile exactly as
before, and forced tool choices, the prompt and validation are unchanged.
