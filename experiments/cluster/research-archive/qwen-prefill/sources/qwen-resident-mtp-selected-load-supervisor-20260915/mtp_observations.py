"""Closed native OS/allocator DTO checks; parent observations remain separate."""
from binding_common import fields, integer, require, same

GIB = 1024**3


def os_observation(value, deadline):
    fields(value, 'startedNanoseconds completedNanoseconds timestampUTC physicalMemoryBytes '
           'pageSizeBytes kernelFreePages freePages inactivePages speculativePages actualFreeBytes '
           'estimatedReclaimableBytes pressureLevel swapUsedBytes', 'native OS observation')
    for name in value:
        if name != 'timestampUTC':
            integer(value[name], name)
    require(type(value['timestampUTC']) is str and 1 <= len(value['timestampUTC']) <= 64, 'Missing native timestamp')
    require(0 < value['startedNanoseconds'] <= value['completedNanoseconds'] < deadline
            and value['completedNanoseconds'] - value['startedNanoseconds'] <= 10**9, 'Native observation clock bounds')
    same(value['physicalMemoryBytes'], 48*GIB, 'This physical check requires the48GiB Mac')
    page = value['pageSizeBytes']
    require(1 <= page <= 65536 and page & (page-1) == 0, 'Native page size invalid')
    same(value['kernelFreePages'], value['freePages']+value['speculativePages'], 'Kernel/free/speculative identity')
    same(value['actualFreeBytes'], value['freePages']*page, 'Native actual-free arithmetic')
    same(value['estimatedReclaimableBytes'],
         (value['freePages']+value['inactivePages']+value['speculativePages'])*page, 'Native reclaimable arithmetic')
    require(6*GIB <= value['actualFreeBytes'] <= value['physicalMemoryBytes'], 'Native actual-free floor')
    require(value['actualFreeBytes'] <= value['estimatedReclaimableBytes'] <= value['physicalMemoryBytes'], 'Native reclaimable bounds')
    integer(value['pressureLevel'], 'native pressure', 0, 2)
    same(value['swapUsedBytes'], 0, 'native swap')


def memory(value, phase, empty_cache=False):
    fields(value, 'phase activeMLXBytes cachedMLXBytes peakMLXBytesSinceProcessStart', 'native memory')
    same(value['phase'], phase, 'memory phase')
    for name in ('activeMLXBytes', 'cachedMLXBytes', 'peakMLXBytesSinceProcessStart'):
        integer(value[name], name)
    require(value['peakMLXBytesSinceProcessStart'] >= value['activeMLXBytes'], 'Memory peak below active')
    if empty_cache:
        same(value['cachedMLXBytes'], 0, 'Native cache not empty')


def runtime(value, pid, deployment):
    required = ('mainBundleName mainBundlePath processID operatingSystemVersion deviceArchitecture '
        'deviceMemoryBytes maximumBufferBytes recommendedWorkingSetBytes '
        'binaryOrBundleHashVerifiedByNative providerEligibilityEstablished recommendedWorkingSetUsedForAdmission').split()
    optional = {'executableName', 'bundleIdentifier', 'executablePath', 'mainBundleResourcePath'}
    require(type(value) is dict and set(required) <= set(value) <= set(required) | optional, 'Runtime keys differ')
    same(value['processID'], pid, 'Native PID')
    same(value['mainBundlePath'], str(deployment), 'Native bundle path')
    same(value['mainBundleName'], deployment.name, 'Native bundle name')
    for key, wanted in [('executableName', 'MTPSelectedLoadCheck'),
                        ('executablePath', str(deployment/'MTPSelectedLoadCheck')),
                        ('mainBundleResourcePath', str(deployment))]:
        if key in value:
            same(value[key], wanted, key)
    same(value['deviceMemoryBytes'], 48*GIB, 'Native device memory')
    integer(value['maximumBufferBytes'], 'Maximum buffer', 508559360)
    integer(value['recommendedWorkingSetBytes'], 'Diagnostic working set', 1)
    for key in ('operatingSystemVersion', 'deviceArchitecture'):
        require(type(value[key]) is str and 1 <= len(value[key]) <= 256, 'Runtime text missing')
    for key in ('binaryOrBundleHashVerifiedByNative', 'providerEligibilityEstablished', 'recommendedWorkingSetUsedForAdmission'):
        same(value[key], False, key)
