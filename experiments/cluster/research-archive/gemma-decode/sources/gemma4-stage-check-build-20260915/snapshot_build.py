"""Pin the assembled source and task-owned dependency checkouts before compiling."""
from pathlib import Path
import hashlib,json
BASE=Path(__file__).resolve().parent

def entries(root, skipped):
    result=[]
    for path in sorted(root.rglob('*')):
        relative=path.relative_to(root)
        if any(part in skipped or part.startswith('.build') for part in relative.parts):continue
        if path.is_file():
            raw=path.read_bytes();item=dict(path=str(relative),bytes=len(raw),sha256=hashlib.sha256(raw).hexdigest())
            if path.is_symlink():item['symlink']=str(path.readlink())
            result.append(item)
    return result

def main():
    source=entries(BASE/'workspace',{'.git','__pycache__'})
    dependencies=entries(BASE/'workspace/libs/darkbloom-cluster-worker/.build-native-worker/checkouts',{'.git','__pycache__'})
    old=BASE.parent/'qwen-mtp-target-session-build-guarded-20260915'
    previous=json.loads((old/'dependency-snapshot-1.json').read_bytes())['members']
    if dependencies!=previous or len(source)!=3090:raise RuntimeError('Source count or exact inherited dependency set differs')
    for name,members in [('source-snapshot-1.json',source),('dependency-snapshot-1.json',dependencies)]:
        with (BASE/name).open('x') as stream:json.dump(dict(members=members),stream,indent=2);stream.write('\n')
    print(json.dumps(dict(sources=len(source),dependencyFiles=len(dependencies),compilerExecuted=False)))
if __name__=='__main__':main()
