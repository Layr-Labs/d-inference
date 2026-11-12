### A nullable tool parameter takes `null`

- A tool parameter a client declares nullable (`"type": ["integer", "null"]`, or `anyOf` with a `null` branch) reaches the model's parser as `"nullable": true`, which the SDK ignored. A model's `null` for it, as Qwen 3.5-family XML calls write it, stayed the string `"null"`, failed the parameter's type, and the client got a tool error for a legal argument. It now becomes JSON `null` and passes validation for a nullable integer, number, boolean, object or array. A nullable string keeps the text `null`, and `enum`, `const` and combinators still apply.
