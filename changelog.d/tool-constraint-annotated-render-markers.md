### Forced tool choices accept `{}` parameters that keep a description

- Under `tool_choice` `required` or a named function, a parameter schema the
  coordinator forwards as a render-marked `{}` that keeps its annotations
  (`description`, `title`, `default`, `examples`, …) now compiles as the bare
  `{}` does, as free text, instead of refusing the request. A marker beside
  an assertion, or one standing for `false`, is still refused. `auto` is
  unchanged. No rendered prompt changes.
