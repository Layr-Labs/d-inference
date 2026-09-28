"""Retain the alias until observed native absence or the bounded lifetime window."""
import os
import signal
import subprocess
import time


def invoke_controller(command, stdout, stderr, receipt, timeout=315):
    child = subprocess.Popen(command, stdout=stdout, stderr=stderr, start_new_session=True)
    receipt.update(pid=child.pid, timeoutSeconds=timeout, killedOwnedGroup=False, reaped=False)
    try:
        receipt['exitCode'] = child.wait(timeout=timeout)
    except BaseException as error:
        receipt['failure'] = type(error).__name__ + ': ' + str(error)
        # The direct child is still unreaped: its new session ID cannot have been
        # reused. Fence this owned group before reaping, never an observed remote PID.
        try:
            os.killpg(child.pid, signal.SIGKILL)
            receipt['killedOwnedGroup'] = True
        except ProcessLookupError:
            receipt['ownedGroupAlreadyAbsent'] = True
        except BaseException as cleanup_error:
            receipt['groupKillError'] = type(cleanup_error).__name__ + ': ' + str(cleanup_error)
            try: child.kill()  # Still the owned Popen handle; retain failed group proof.
            except ProcessLookupError: pass
        finally:
            try: receipt['exitCode'] = child.wait(timeout=10)
            except BaseException as cleanup_error:
                receipt['reapError'] = type(cleanup_error).__name__ + ': ' + str(cleanup_error)
        raise
    finally:
        receipt['reaped'] = child.returncode is not None
        if receipt['reaped']:
            try: os.killpg(child.pid, 0)
            except ProcessLookupError: receipt['groupAbsent'] = True
            except BaseException as error:
                receipt['groupAbsent'] = False
                receipt['groupProbeError'] = type(error).__name__ + ': ' + str(error)
            else: receipt['groupAbsent'] = False


def observe_retirement(deadline, collect, publish, clock=time.monotonic, sleep=time.sleep):
    """A time bound ends observation; it never manufactures absence or clears a journal."""
    result = dict(nativeProcessesAbsent=False, journalsEmpty=False, observationErrors=[], samples=0,
                  ownershipWindowExpired=False)
    while clock() < deadline:
        try:
            values = []
            for rank in (0, 1):
                remaining = deadline - clock()
                if remaining <= 0: raise TimeoutError('Native cleanup observation window ended')
                value = collect(rank, min(15, remaining))
                if (type(value) is not dict or type(value.get('active')) is not list or
                        type(value.get('journalBytes')) is not int or value['journalBytes'] < 0):
                    raise ValueError('Malformed process/journal postflight')
                publish(dict(rank=rank, observation=result['samples'], **value))
                values.append(value)
            result['samples'] += 1
            result['postflight'] = values
            result['nativeProcessesAbsent'] = all(not value['active'] for value in values)
            result['journalsEmpty'] = all(value['journalBytes'] == 0 for value in values)
            if result['nativeProcessesAbsent']:
                return result  # A sticky journal still makes the overall run fail.
        except BaseException as error:
            # Complete bounded cleanup even if the operator interrupts this wait.
            detail = type(error).__name__ + ': ' + str(error)
            result['observationErrors'].append(detail)
            result['nativeProcessesAbsent'] = False; result['journalsEmpty'] = False
            if not isinstance(error, Exception): result['interrupted'] = detail
        remaining = deadline - clock()
        if remaining <= 0: break
        try: sleep(min(1, remaining))
        except BaseException as error:
            detail = type(error).__name__ + ': ' + str(error)
            result['observationErrors'].append(detail)
            result['interrupted'] = detail
    result['ownershipWindowExpired'] = True
    return result
