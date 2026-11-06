"""Closed cache-off diagnostic metadata; no active-allocation admission changes."""
from physical_common import exact, fields, integer, require


def validate_allocator_policy(value, loaded_bytes):
    fields(value, 'schema requestedCacheLimitBytes beforeReadyCacheClear afterReadyCacheClear '
           'activeAllocationLimitChanged cacheLimitGetterUsedAsBackendProof', 'allocator policy')
    for key, expected in dict(schema='qwen_resident_rank_allocator_cache_disabled_v1',
            requestedCacheLimitBytes=0, activeAllocationLimitChanged=False,
            cacheLimitGetterUsedAsBackendProof=False).items():
        exact(value[key], expected, 'Allocator policy ' + key)
    before, after = value['beforeReadyCacheClear'], value['afterReadyCacheClear']
    for snapshot in [before, after]:
        fields(snapshot, 'activeMemory cacheMemory peakMemory', 'allocator snapshot')
        for amount in snapshot.values(): integer(amount)
        require(snapshot['peakMemory'] >= snapshot['activeMemory'] >= loaded_bytes,
                'Allocator active/peak differs from resident source')
    require(after['cacheMemory'] == 0 and after['activeMemory'] == before['activeMemory']
            and after['peakMemory'] == before['peakMemory'], 'Cache clear did not preserve active storage')
