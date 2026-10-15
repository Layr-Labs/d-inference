"""Small source/authority check only. Does not copy a workspace/cache or build."""
import ast,json
from pathlib import Path
from build_inputs import BASE,inputs,sha

def main():
    v,old,draft,source,overlay=inputs()
    for path in BASE.glob('*.py'):ast.parse(path.read_text(),filename=str(path))
    source_by_path={r['path']:r for r in source}
    for row in overlay:
        before=source_by_path.get(row['path'])
        assert (before['sha256'] if before else None)==row['beforeSHA256']
        assert sha(draft/'proposed'/row['path'])==row['afterSHA256']
    assert v['expectedSourceCount']==len(source)+sum(r['beforeSHA256'] is None for r in overlay)==3096
    command=(BASE/'build_native.py').read_text()
    assert "PRODUCTS=('WindowedRequestStateCheck','TargetVerificationSessionCheck','TargetVerificationCheck')" in command
    assert "'-DCBV2_WINDOW_STATE_FIXTURE'" in command and "'-DQWEN_TARGET_TINY_FIXTURE'" in command
    assert "name+'-build',900" in command and "'check-arguments'" in command
    assert 'run-windowed-state-on-gpu' not in command and 'run-tiny-session-on-gpu' not in command
    assert not (BASE/'workspace').exists()
    print(json.dumps(dict(pythonSyntax=True,exactHelpers=True,overlayFiles=28,baseSources=3075,expectedComposedSources=3096,
        baseDependencies=8755,workspaceMaterialized=False,cacheCloned=False,compilerExecuted=False,nativeExecuted=False),sort_keys=True))
if __name__=='__main__':main()
