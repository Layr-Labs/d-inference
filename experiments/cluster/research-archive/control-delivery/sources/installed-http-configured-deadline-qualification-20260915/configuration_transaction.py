"""Two-host transaction ordering; every path attempts both exact restorations."""
HOSTS = ('darkbloom-24', 'darkbloom-48')


def transact(action, physical, prepared=None, restore_only=False):
    pins = dict(prepared or {})
    record = dict(prepared={}, installed={}, restored={}, restorationErrors={},
                  physical=None, error=None, defaultsRestored=False, qualified=False)
    try:
        if not restore_only:
            for host in HOSTS:
                receipt = action(host, 'prepare', None)
                pins[host] = receipt['afterSHA256']
                record['prepared'][host] = receipt
            for host in HOSTS:
                record['installed'][host] = action(host, 'install', pins[host])
            record['physical'] = physical()
    except BaseException as error:
        record['error'] = type(error).__name__ + ': ' + str(error)
    finally:
        for host in HOSTS:
            try:
                receipt = action(host, 'restore', pins.get(host))
                if receipt.get('restored') is not True:
                    raise ValueError('Exact original restoration was not verified')
                record['restored'][host] = receipt
            except BaseException as error:
                record['restorationErrors'][host] = type(error).__name__ + ': ' + str(error)
        record['defaultsRestored'] = len(record['restored']) == 2 and not record['restorationErrors']
    record['qualified'] = (record['defaultsRestored'] and record['error'] is None
                           and (restore_only or (record['physical'] or {}).get('terminalObservationQualified') is True))
    return record
