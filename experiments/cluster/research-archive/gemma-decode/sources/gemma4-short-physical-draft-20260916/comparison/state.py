"""Exact actual Gemma attention layouts and chronological state byte comparison."""
import math
import struct
from contract import FLOATS, GLOBALS, bounded, fields, text_hash
from recorded_math import WIDTH, digest, equal, require, sha_string

COMPONENTS = ('kv.keys','kv.position_offsets','kv.values')


def layers(binding, mode_index):
    values = binding['layers']
    require(type(values) is list and len(values)==len(GLOBALS[mode_index]),'Complete layer binding')
    lines = ['attention-state-layout-v1','maximumTokens=34','maximumChunkTokens=16','prefix=false','speculation=false']
    for local,(global_index,layer) in enumerate(zip(GLOBALS[mode_index],values)):
        fields(layer,'localIndex globalIndex kvHeads headDimension window dtype')
        full = global_index % 6 == 5
        require(layer['dtype'] in FLOATS,'Unknown actual KV dtype')
        equal(layer,dict(localIndex=local,globalIndex=global_index,kvHeads=2 if full else 8,
            headDimension=512 if full else 256,window=0 if full else 1024,dtype=layer['dtype']), 'Exact global Gemma geometry')
        lines.append(f"{local}|{global_index}|{layer['kvHeads']}|{layer['headDimension']}|{'full' if full else 1024}|{layer['dtype']}")
    equal(binding['stateLayoutSHA256'],text_hash(lines),'Actual state-layout fingerprint')
    return values


def finite(raw, dtype):
    if dtype == 'bfloat16':
        for (bits,) in struct.iter_unpack('<H',raw):
            require((bits & 0x7f80) != 0x7f80,'Nonfinite BF16 state')
    else:
        for (value,) in struct.iter_unpack('<e' if dtype=='float16' else '<f',raw):
            require(math.isfinite(value),'Nonfinite native state')


def state(value, binding, sidecars, mode_index):
    fields(value,'frontier fingerprint entries')
    equal(value['frontier'],33,'Final committed frontier')
    actual_layers = layers(binding,mode_index)
    expected_order = [(g,c) for g in GLOBALS[mode_index] for c in COMPONENTS]
    entries = value['entries']
    require(type(entries) is list and len(entries)==len(expected_order),'Complete named-state count')
    result, identities, files = {}, [], []
    for entry,(global_index,component) in zip(entries,expected_order):
        fields(entry,'localLayerIndex globalLayerIndex component dtype sha256 shape byteCount logicalRange file')
        local = GLOBALS[mode_index].index(global_index)
        layer = actual_layers[local]
        equal([entry['localLayerIndex'],entry['globalLayerIndex'],entry['component']],
              [local,global_index,component],'Exact state order/global-local mapping')
        position = component=='kv.position_offsets'
        dtype = 'int32' if position else layer['dtype']
        shape = [1] if position else [1,layer['kvHeads'],33,layer['headDimension']]
        logical_range = [] if position else [0,33]
        byte_count = math.prod(shape)*WIDTH[dtype]
        equal([entry['shape'],entry['dtype'],entry['byteCount'],entry['logicalRange']],
              [shape,dtype,byte_count,logical_range],'State temporal shape/type/bytes')
        equal(entry['file'],dict(name=f'state-{global_index}-{component}.bin',bytes=byte_count,
            sha256=sha_string(entry['sha256'])),'State file binding')
        raw = sidecars.read(entry['file'])
        equal(digest(raw),entry['sha256'],'State logical-byte hash')
        if position: require(raw==struct.pack('<i',33),'Actual position frontier bytes')
        else: finite(raw,dtype)
        identity = f"{global_index}|{component}|{shape}|{dtype}|{byte_count}|{entry['sha256']}"
        if not position: identity += '|range=0:33'
        identities.append(identity)
        result[(global_index,component)] = dict(shape=shape,dtype=dtype,byteCount=byte_count,
            logicalRange=logical_range,sha256=entry['sha256'],raw=raw)
        files.append(entry['file'])
    equal(value['fingerprint'],text_hash(['cbv2-owned-attention-state-v2',binding['stateLayoutSHA256'],'tokens=33']+identities),
          'Actual snapshot fingerprint')
    return result,files


def compare_states(full, left, right):
    require(not (set(left)&set(right)) and set(full)==set(left)|set(right),'Exact disjoint global-state union')
    for key,candidate in left.items():
        require(candidate==full[key],'Stage0 native state differs: '+str(key))
    for key,candidate in right.items():
        require(candidate==full[key],'Stage1 native state differs: '+str(key))
