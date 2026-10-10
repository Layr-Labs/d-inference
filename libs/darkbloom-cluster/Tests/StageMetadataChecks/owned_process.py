"""Exact reviewed owned-child cleanup helper, plus a launch PID observation."""
import os
import signal
import subprocess


def invoke_controller(command, stdout, stderr, receipt, timeout=315):
    child = subprocess.Popen(command, stdout=stdout, stderr=stderr, start_new_session=True)
    receipt.update(pid=child.pid, timeoutSeconds=timeout, killedOwnedGroup=False, reaped=False)
    print('owned-child pid ' + str(child.pid), flush=True)
    try:
        receipt['exitCode'] = child.wait(timeout=timeout)
    except BaseException as error:
        receipt['failure'] = type(error).__name__ + ': ' + str(error)
        # Popen.wait may reap during its own KeyboardInterrupt handler before
        # rethrowing. Only the already-published, unreaped state authorizes a
        # destructive group signal. Do not poll or reap before this decision.
        if child.returncode is None:
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
        else:
            receipt['exitCode'] = child.returncode
            receipt['reapedBeforeExceptionCleanup'] = True
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
