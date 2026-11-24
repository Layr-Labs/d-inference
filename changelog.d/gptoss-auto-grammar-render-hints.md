### GPT-OSS auto tool grammar reads the repair's render type as a hint

Under `tool_choice: "auto"`, GPT-OSS's call grammar compiles each declared
tool's arguments. Beside a `not` of the same type, the schema repair writes a
`type` (`{"not": {"type": "string"}, "type": "string"}`), and the grammar held
the argument to that type, which the declaration itself refuses. The grammar
now drops a type that is only a render hint (beside a union naming it, a
mixed `enum`, a `not` of that type or an `if` typed otherwise), as the call
parser and the strict check already do, and keeps `null` where the node is
marked `nullable`. Unions and mixed enums with that type were already left
free and still are; declarations without such a type compile exactly as
before, and forced tool choices, the prompt and validation are unchanged.
