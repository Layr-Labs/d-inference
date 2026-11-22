### Gemma 4 26B: the same stored checkpoints before and after the assistant attaches

- A Gemma 4 26B QAT provider that starts target-only (the catalog metadata or
  the MTP assistant isn't ready yet) and attaches its assistant later now keeps
  the assistant's two access layers native from the start. Prefix-cache
  checkpoints written before the assistant attaches encode those layers as the
  later ones do, so cached prompts give the same answers whichever happened
  first.
