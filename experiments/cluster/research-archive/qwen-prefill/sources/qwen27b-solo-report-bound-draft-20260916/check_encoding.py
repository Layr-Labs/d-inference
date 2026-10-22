"""Root-granted bounded Foundation encoding check, before materialization/build."""
import json
import os
import sys
import time
from build_inputs import BASE, digest, verify_preparation
from check_preparation import check
from owned_process import invoke_controller


def main():
    attempt, = sys.argv[1:]
    if not attempt.isdecimal() or not 1 <= int(attempt) <= 99:
        raise ValueError('Expected fresh numeric encoding-check attempt')
    out = BASE/('encoding-'+attempt); out.mkdir(mode=0o700)
    binary = out/'ReportEncodingCheck'
    generated = BASE/'Tests/generated'
    commands = [
        ('compile', ['/usr/bin/xcrun','swiftc','-O','-j','2',str(generated/'ExactDTOs.swift'),
                     str(BASE/'Tests/ReportEncodingCheck.swift'),'-o',str(binary)], 90),
        ('encode', [str(binary),str(generated/'cases.json'),str(out/'reports')], 30),
        ('parse', ['/usr/bin/python3','-B',str(BASE/'Tests/test_report_bounds.py'),
                   '--swift-output',str(out/'reports')], 30),
    ]
    receipt = dict(schema='solo_report_foundation_encoding_check_v1', steps=[],
                   modelOrKernelExecuted=False, runtimeConstructorsUsed=False)
    failure = None
    try:
        receipt['buildPreparationManifestSHA256'] = verify_preparation()
        receipt['sourceCheck'] = check()
        for name, argv, timeout in commands:
            step = dict(name=name, argv=argv); receipt['steps'].append(step)
            began = time.monotonic()
            try:
                with (out/(name+'.stdout')).open('xb') as stdout, (out/(name+'.stderr')).open('xb') as stderr:
                    invoke_controller(argv, stdout, stderr, step, timeout=timeout)
            finally:
                step['elapsedSeconds'] = time.monotonic()-began
                (out/'receipt.json').write_text(json.dumps(receipt,indent=2,sort_keys=True)+'\n')
            if step.get('exitCode') != 0 or not step.get('reaped') or not step.get('groupAbsent'):
                raise ValueError('Encoding fixture failed or owned group remains')
        result = json.loads((out/'encode.stdout').read_bytes())
        if (result.get('kind') != 'solo_report_encoding_check' or result.get('oldLimitRejections') != 3
                or result.get('boundaryAccepted') != 2 or result.get('boundaryRejected') != 2
                or result.get('modelOrKernelExecuted') is not False or result.get('actualPerformanceEvidence') is not False
                or len(result.get('reportBytes',[])) != 3
                or not all(128*1024 < n <= 512*1024 for n in result['reportBytes'])):
            raise ValueError('Native Foundation encoding result differs')
        receipt['result'] = result
    except BaseException as error:
        failure = error; receipt['failure'] = type(error).__name__+': '+str(error)
    finally:
        try:
            receipt['after'] = check()
            if verify_preparation() != receipt.get('buildPreparationManifestSHA256'):
                raise ValueError('Frozen sources changed during Foundation check')
        except BaseException as error:
            receipt['sourceFailure'] = type(error).__name__+': '+str(error)
            if failure is None: failure = error
        receipt['passed'] = failure is None
        receipt['outputs'] = {str(p.relative_to(out)):dict(bytes=p.stat().st_size,sha256=digest(p))
                              for p in sorted(out.rglob('*')) if p.is_file() and p.name!='receipt.json'}
        (out/'receipt.json').write_text(json.dumps(receipt,indent=2,sort_keys=True)+'\n')
    if failure is not None: raise failure
    print(json.dumps(dict(passed=True,result=receipt['result'])))


if __name__ == '__main__':
    os.umask(0o077)
    main()
