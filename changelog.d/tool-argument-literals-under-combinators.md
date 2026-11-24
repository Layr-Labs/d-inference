### Tool-call arguments read JSON literals under combinator schemas

- A tool-call argument whose schema has no single non-string type (`not`, `if`/`then`/`else`, a union that admits a string, or no type) now reads a value written as a JSON literal, such as `-2500`, as that literal when the schema admits it and rejects the text as a string. Before, such values stayed strings and failed the schema. Values the check cannot decide keep their text.
