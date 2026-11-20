### GLM-5.3-Flash: a refused prefix restore no longer stops the provider

- A GLM-5.3-Flash request submitted with a first-token deadline prepares its
  prefix-cache restore before publishing it. When the restore was refused
  under memory pressure, releasing the request added its MTP assistant's
  charge, which the restore's checkpoint stage still held, to the engine's
  memory ledger. The ledger refused that growth and the provider stopped with
  a Swift trap, then restarted about 6 minutes later.
- The release now leaves that charge on the stage, which refunds it once the
  restore's native work retires (mlx-swift-lm `995f3a5e`, the 0.10.16 SDK pin
  plus this fix). Other models and published restores are unchanged.
