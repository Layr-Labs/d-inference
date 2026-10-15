"""Small source/metadata checks only, never prepares or compiles the workspace."""
import ast,json,sys
from pathlib import Path
BASE=Path(__file__).resolve().parent
sys.path.insert(0,str(BASE/'build'))
from build_inputs import inputs,sha

def main():
    value,old,_,source,overlay=inputs()
    index={r['path']:r['sha256'] for r in source}
    integration=json.loads((BASE/'build/integration.json').read_bytes())
    for path,chain in integration['compositionChains'].items():
        current=index.get(path)
        for row in chain:
            if row['beforeSHA256']!=current or sha(Path(row['source']))!=row['afterSHA256']:
                raise ValueError('Broken exact overlay chain: '+path)
            current=row['afterSHA256']
        if next(r for r in overlay if r['path']==path)['afterSHA256']!=current:raise ValueError('Wrong final overlay')
    if len(set(index)|{r['path'] for r in overlay})!=value['expectedSourceCount']:raise ValueError('Wrong projected source count')
    session=(BASE/'proposed/Runtime/Gemma4OwnedForwardSession.swift').read_text()
    begin=session.index('    /// CPU metadata projection only.');end=session.index('    func snapshot(',begin)
    if session[:begin]+session[end:]!=(BASE/'originals/Gemma4OwnedForwardSession.swift').read_text():
        raise ValueError('Session change is not the isolated metadata getter')
    owner=(BASE/'proposed/Runtime/Gemma4ShortCorrectness.swift').read_text()
    owner=owner.replace('    check: () throws -> Void,\n    body: (Gemma4OwnedForwardSession, () throws -> Void) throws -> Data',
        '    check: () throws -> Void, body: (Gemma4OwnedForwardSession) throws -> Data')
    owner=owner.replace('try body(session, checked)','try body(session)')
    if owner!=(BASE/'originals/Gemma4ShortCorrectness.swift').read_text():raise ValueError('Resource owner signature changed beyond check threading')
    for path in [BASE/'verify_sources.py']+sorted((BASE/'build').glob('*.py')):
        ast.parse(path.read_text(),filename=str(path))
    print(json.dumps(dict(passed=True,baseSources=len(source),composedSources=value['expectedSourceCount'],overlayFiles=len(overlay),
        sessionMathAndLifecycleInverse=True,resourceBodySignatureInverse=True,sourceOnly=True,
        compilerExecuted=False,workspacePrepared=False,modelOrRemoteExecuted=False),sort_keys=True))
if __name__=='__main__':main()
