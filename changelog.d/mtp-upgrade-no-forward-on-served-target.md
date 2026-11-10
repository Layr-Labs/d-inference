### MTP assistant upgrade: no forward on the model while it serves

- When a provider attaches the verified MTP assistant to a model that is already serving (the idle upgrade), building the replacement engine no longer runs a forward on that model. It reuses the KV types observed when the model was first loaded.
- A forward from the preparing thread could race the serving engine. With Gemma 4's compiled feed-forward (in the next SDK), that race crashed the provider with `Attempting to eval an array without a primitive` when a request arrived during the upgrade, typically the first request after a start.
