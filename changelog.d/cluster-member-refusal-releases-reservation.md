### Cluster member refusals and stops release what they hold

- A cluster member that refuses an inference request because it has no live pair slot now sends `service_reservation_released` with its 503, on the receive path, in the dispatcher and in the request handler. A request that raced a pair-slot retirement left its reservation held on the coordinator before. The handler refusal also settles the request's prefix-cache lookup receipt. The 503 answer is unchanged.
- A session that ends while the leader still forms its pair (slot publication and warmup canary) retires the published slot before the leader sends `native_pair_owner_released`. The receipt went out while the slot was still published before.
