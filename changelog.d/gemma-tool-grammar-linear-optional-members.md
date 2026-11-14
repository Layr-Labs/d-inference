### Gemma forced tool-call grammar stays linear in nested optional objects

- A required or named `tool_choice` on Gemma 4 built a property's value once
  for each way the members before it could have been emitted, so an optional
  object nested under optional siblings was copied twice per level: a schema
  within every compiler limit could build millions of states (a depth-16 chain
  2.5 million; one near the grammar-cost ceiling projects to billions) before
  the 100,000-state check refused it. Each property's `name:value` tail is now
  built once per object and shared, which accepts exactly the same calls.
- The 100,000-state limit is enforced while the grammar is built, so any
  schema past it is refused within one value of the limit.
