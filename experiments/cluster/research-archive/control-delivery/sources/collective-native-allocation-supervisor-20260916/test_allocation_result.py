"""Independent small report controls; fake values confer no native qualification."""
import copy
import hashlib
import json
from pathlib import Path
import sys
import unittest
sys.path.insert(0, str(Path(__file__).parent/'package'))
from allocation_result import validate_result

HOST = dict(physicalMemoryBytes=24*1024**3, pageSizeBytes=16384, cpuBrand='Apple M4 Pro', hardwareModel='FixtureMac', osBuild='FixtureOS')


def report(kind='scalar'):
    r = dict(schema='collective_native_allocation_probe_v1',
        scope='both codec endpoints plus native staging in one process; no RDMA/group/model',
        profileQualified=False, caseID='fresh-u32-4', failureMode='none', hardwareModel='FixtureMac', osBuild='FixtureOS',
        suite='aes256GcmHkdfSha256V1', allocatorPolicy='disable_freed_buffer_cache',
        maximumPlaintextBytes=10485760, maximumFrameBytes=10485800, maximumInFlightOperations=1,
        rounds=32, geometries=[dict(id='u32-4',shape=[1],dtype='uint32',plaintextBytes=4,nativeArrayBoundBytes=7,nativeFrameBoundBytes=87)],
        elapsedNanoseconds=1000000, baselineNativeActiveBytes=0, observedPeakNativeActiveBytes=1024,
        maximumObservedNativeCacheBytes=0, finalNativeActiveBytes=0, finalNativeCacheBytes=0,
        baselinePhysical=dict(currentBytes=1000000,lifetimeMaximumBytes=1100000),
        finalPhysical=dict(currentBytes=1200000,lifetimeMaximumBytes=1500000),
        conservativeObservedPhysicalIncrementBytes=500000, sentRecords=32, openedRecords=32,
        publishedArrays=32, refusedRecords=0, frameLengths=[44]*32, plaintextByteCounts=[4]*32,
        actualInputByteCounts=[4]*32, attemptedNativeShapes=[[1]]*32, attemptedNativeDTypes=['uint32']*32,
        primingOperations=0, unauthenticatedArraysPublished=0,
        verifiedPlaintextDigests=[hashlib.sha256(b'ZZZZ').hexdigest()]*32,
        senderActiveBeforeCleanup=True,receiverActiveBeforeCleanup=True,
        allTrackedNativeArraysReleased=True,nativeAllocationsReturnedToBaseline=True)
    if kind == 'session':
        r.update(caseID='session-only', rounds=1, geometries=[], sentRecords=0, openedRecords=0,
            publishedArrays=0, frameLengths=[],plaintextByteCounts=[],actualInputByteCounts=[],attemptedNativeShapes=[],
            attemptedNativeDTypes=[],verifiedPlaintextDigests=[])
    elif kind == 'afterOpen':
        r.update(caseID='failure-afterOpen',failureMode='afterOpen',rounds=1,
            geometries=[dict(id='f32-512x5120',shape=[1,512,5120],dtype='float32',plaintextBytes=10485760,
                nativeArrayBoundBytes=10518527,nativeFrameBoundBytes=10534911)],
            sentRecords=1,openedRecords=1,publishedArrays=0,refusedRecords=1,frameLengths=[10485800],
            plaintextByteCounts=[10485760],actualInputByteCounts=[10485760],attemptedNativeShapes=[[1,512,5120]],
            attemptedNativeDTypes=['float32'],verifiedPlaintextDigests=[],receiverActiveBeforeCleanup=False)
    return r


class AllocationReports(unittest.TestCase):
    def check(self, value, host=HOST):
        return validate_result(json.dumps(value).encode(), value['caseID'], host)

    def test_independent_scalar_session_and_post_open_refusal(self):
        for kind in ('scalar','session','afterOpen'):
            with self.subTest(kind=kind): self.check(report(kind))

    def test_false_success_and_scope_or_geometry_substitution_refused(self):
        for key, value in [('profileQualified',True),('unauthenticatedArraysPublished',1),('sentRecords',31),
            ('openedRecords',33),('publishedArrays',0),('refusedRecords',1),('rounds',31),
            ('frameLengths',[43]*32),('actualInputByteCounts',[8]*32),('verifiedPlaintextDigests',['0'*64]*32),
            ('allTrackedNativeArraysReleased',False),('nativeAllocationsReturnedToBaseline',False),
            ('senderActiveBeforeCleanup',False),('maximumInFlightOperations',2)]:
            with self.subTest(key=key):
                r=report();r[key]=value
                with self.assertRaises(ValueError):self.check(r)

    def test_native_footprint_deadline_and_identity_bounds(self):
        for key,value in [('observedPeakNativeActiveBytes',256*1024**2+1),('finalNativeActiveBytes',1),
            ('maximumObservedNativeCacheBytes',1),('finalNativeCacheBytes',1),('elapsedNanoseconds',55*10**9),
            ('elapsedNanoseconds',True),('hardwareModel','OtherMac'),('osBuild','OtherOS')]:
            with self.subTest(key=key):
                r=report();r[key]=value
                with self.assertRaises(ValueError):self.check(r)
        r=report();r['finalPhysical']['lifetimeMaximumBytes']=1000000+512*1024**2+1
        r['conservativeObservedPhysicalIncrementBytes']=512*1024**2+1
        with self.assertRaises(ValueError):self.check(r)
        host=copy.deepcopy(HOST);host['pageSizeBytes']=4096
        with self.assertRaises(ValueError):self.check(report(),host)

    def test_duplicate_unknown_and_unauthenticated_publication_refused(self):
        raw=json.dumps(report()).encode();raw=raw[:-1]+b',"caseID":"fresh-u32-4"}'
        with self.assertRaises(ValueError):validate_result(raw,'fresh-u32-4',HOST)
        r=report();r['extra']=0
        with self.assertRaises(ValueError):self.check(r)
        r=report('afterOpen');r['publishedArrays']=1
        with self.assertRaises(ValueError):self.check(r)


if __name__ == '__main__': unittest.main()
