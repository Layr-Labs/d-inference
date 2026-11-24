### Gemma 4 prompts keep the tool-schema node budget

- A request whose tool schemas have more than 100,000 nodes is decoded as
  sent, without the default-type repair. On Gemma 4 the prompt step repaired
  the same schemas again with no limit, turning each empty schema in a large
  `anyOf` into a new map. It now shares one 100,000-node budget across the
  request's tools and leaves a schema past it as sent. Tool schemas within the
  budget are repaired as before.
