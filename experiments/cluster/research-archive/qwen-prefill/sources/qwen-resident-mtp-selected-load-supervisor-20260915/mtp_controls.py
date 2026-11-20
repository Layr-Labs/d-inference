"""Load the frozen prospective metadata controls shipped with this package."""
import hashlib
import math

from binding_common import fields, integer, parse, require, same


def read_controls(root, pins):
    target = parse(pins.read(root/'inputs/target-control.json', 2*1024**2)['raw'])
    arithmetic = parse(pins.read(root/'inputs/arithmetic.json', 65536)['raw'])
    additional = parse(pins.read(root/'inputs/additional-tensors.json', 65536)['raw'])
    devices = pins.read(root/'inputs/devices.json', 4096)['raw']
    same(target['planSHA256'], '67bf0b1bf94f229682df58ae1ae10c758e2a386d66d3e1b68146f5c090f6309f', 'Control Plan')
    same(len(target['activeTensors']), 809, 'Control active count')
    same(target['loadedTensorBytes'], 3979190464, 'Control selected bytes')
    same(target['inertTensorBytes'], 8192, 'Control inert bytes')
    require(type(additional) is list and len(additional) == 34, 'Additional control coverage')
    names = set()
    for value in additional:
        fields(value, 'name shape sourceDType byteCount', 'additional tensor')
        require(type(value['name']) is str and value['name'] not in names, 'Repeated tensor name')
        names.add(value['name'])
        require(value['sourceDType'] in ('U32', 'BF16') and type(value['shape']) is list
                and 1 <= len(value['shape']) <= 2, 'Additional tensor type/shape')
        for dimension in value['shape']:
            integer(dimension, 'tensor dimension', 1, 248320)
        same(value['byteCount'], math.prod(value['shape'])*(4 if value['sourceDType']=='U32' else 2), 'Tensor bytes')
    same(sum(x['byteCount'] for x in additional), 709010432, 'Additional byte sum')
    same(parse(devices), [[None,'rdma_en1'],['rdma_en1',None]], 'Device matrix')
    return dict(target=target, arithmetic=arithmetic, additional=additional, devicesRaw=devices)
