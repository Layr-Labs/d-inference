### GLM-5.3-Flash: a request whose prefix restore is refused gets its own assistant

- When a GLM-5.3-Flash prefix-cache restore was refused for an ordinary
  request (one without a first-token deadline), the request continued with a
  cold prefill. Until the refused restore finished retiring, the request's MTP
  assistant could be set up on the restore's binding, whose memory the restore
  still held. If the restore then retired while that assistant still held
  allocations on its binding, the engine could stop with a native completion
  failure, failing that request and the others on the engine.
- The request now gets its own assistant binding. The refused restore keeps
  its memory until it retires (mlx-swift-lm `6f5cc339`, the current SDK pin
  plus this fix).
