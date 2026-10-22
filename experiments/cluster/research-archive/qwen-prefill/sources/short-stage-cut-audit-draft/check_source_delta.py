"""CPU/source check that the numerical block is retained from the frozen oracle."""
import ast
import hashlib
import json
from pathlib import Path


def check():
    folder = Path(__file__).parent
    old_raw = (folder.parent/'qwen_layer_stage_recorded_audit.py').read_bytes()
    new_raw = (folder/'qwen_layer_stage_cut12_audit.py').read_bytes()
    assert hashlib.sha256(old_raw).hexdigest() == 'ba943e3ec2157447d7725ab3ca030bb398813c82be6d4d4a1024d4fbf98d29e4'
    old = {node.name:node for node in ast.parse(old_raw).body if isinstance(node,ast.FunctionDef)}
    new = {node.name:node for node in ast.parse(new_raw).body if isinstance(node,ast.FunctionDef)}
    assert set(old) == set(new)
    unchanged = [name for name in old if name not in {'stage_inventory','check_recorded_pair'}]
    assert all(ast.dump(old[name],include_attributes=False) == ast.dump(new[name],include_attributes=False) for name in unchanged)
    start = "    recorded = baseline['request']; spec = recorded['request']"
    end = "    return dict(status='passed'"
    assert old_raw.decode().split(start,1)[1].split(end,1)[0] == new_raw.decode().split(start,1)[1].split(end,1)[0]
    return dict(kind='cut12_recorded_oracle_source_delta',passed=True,
        originalHelperSHA256=hashlib.sha256(old_raw).hexdigest(),newHelperSHA256=hashlib.sha256(new_raw).hexdigest(),
        unchangedFunctions=unchanged,changedFunctions=['stage_inventory','check_recorded_pair'],
        requestFrameStateLogitMemoryAndResourceChecksByteIdentical=True,nativeExecution=False)


if __name__ == '__main__':
    print(json.dumps(check(),sort_keys=True,indent=2))
