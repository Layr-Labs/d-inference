import copy
import unittest

from allocator_policy import validate_allocator_policy


class AllocatorPolicy(unittest.TestCase):
    def test_closed_cache_policy_and_live_storage(self):
        value=dict(schema='qwen_resident_rank_allocator_cache_disabled_v1',requestedCacheLimitBytes=0,
            activeAllocationLimitChanged=False,cacheLimitGetterUsedAsBackendProof=False,
            beforeReadyCacheClear=dict(activeMemory=20,cacheMemory=5,peakMemory=30),
            afterReadyCacheClear=dict(activeMemory=20,cacheMemory=0,peakMemory=30))
        validate_allocator_policy(value,20)
        for mutate in [lambda x:x.update(requestedCacheLimitBytes=64*1024**2),
            lambda x:x.update(activeAllocationLimitChanged=True),
            lambda x:x.update(cacheLimitGetterUsedAsBackendProof=True),
            lambda x:x.update(extra=True),lambda x:x['afterReadyCacheClear'].update(cacheMemory=1),
            lambda x:x['afterReadyCacheClear'].update(activeMemory=19),
            lambda x:x['afterReadyCacheClear'].update(activeMemory=21),
            lambda x:x['afterReadyCacheClear'].update(peakMemory=31),
            lambda x:x['beforeReadyCacheClear'].update(cacheMemory=True)]:
            changed=copy.deepcopy(value);mutate(changed)
            with self.subTest(mutate=mutate),self.assertRaises(ValueError):validate_allocator_policy(changed,20)


if __name__=='__main__':unittest.main()
