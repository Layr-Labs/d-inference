"""CPU fixture derived from the pinned Swift DTO source, not the oracle dict."""
import hashlib
import json
from pathlib import Path
import re

SOURCE = Path(__file__).resolve().parent/'originals'/'QwenLongPrefillArithmeticEnvironment.swift'
SOURCE_SHA256 = 'b6b9036557a3a937a454d0a8e1b3ba6032954a93c2ded370a97b23d6f984454f'
STRING = r'"(?:[^"\\]|\\.)*"'


def string_map(body):
    pairs = re.findall('('+STRING+r')\s*:\s*('+STRING+')', body)
    remainder = re.sub('('+STRING+r')\s*:\s*('+STRING+r')\s*,?', '', body)
    assert not remainder.strip(), 'Unparsed native string dictionary'
    result = {json.loads(key):json.loads(value) for key,value in pairs}
    assert len(result) == len(pairs) and pairs
    return result


def native_arithmetic_receipt():
    raw = SOURCE.read_bytes()
    assert len(raw) < 65536 and hashlib.sha256(raw).hexdigest() == SOURCE_SHA256
    text = raw.decode()
    declaration = text.split('struct Receipt: Encodable, Equatable {',1)[1].split('\n    }',1)[0]
    fields = set(re.findall(r'\blet (\w+)\s*(?:=|:)', declaration))
    constants = dict(re.findall(r'\blet (\w+) = (true|false)\b', declaration))
    result = {key:value == 'true' for key,value in constants.items()}
    result['contract'] = json.loads(re.search('static let contract = ('+STRING+')',text).group(1))
    result['requiredValues'] = string_map(text.split('static let requiredValues: [String: String] = [',1)[1].split('\n    ]',1)[0])
    result['requiredAbsentNames'] = json.loads(re.search(r'static let requiredAbsentNames = (\[[^\n]+\])',text).group(1))
    initializer = text.split('return .init(contract:',1)[1]
    result['full512TokenChunkQueryBlocks'] = int(re.search(r'full512TokenChunkQueryBlocks: (\d+)',initializer).group(1))
    result['defaultBindings'] = string_map(initializer.split('defaultBindings: [',1)[1].split('\n            ])',1)[0])
    assert set(result) == fields, 'Native arithmetic DTO has an unrepresented field'
    return result
