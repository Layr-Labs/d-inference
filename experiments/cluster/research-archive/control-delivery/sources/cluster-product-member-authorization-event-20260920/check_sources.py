import ast
from common import BASE, inputs, read, require, sha

def main():
    c,w,before,after=inputs()
    for path in BASE.glob('*.py'):ast.parse(path.read_text(),filename=str(path))
    rows=read(BASE/'overlay.json');require(len(rows)==2 and len(before)==len(after)==14111,'Exact two-file composition required')
    for row in rows:
        require(sha(BASE/'original'/row['path'])==row['beforeSHA256'] and sha(BASE/'proposed'/row['path'])==row['sha256'],'Source inverse pins differ')
        require(sha(w/row['path']) in (row['beforeSHA256'],row['sha256']),'Scratch source not an exact before/after')
    runtime=rows[0]['path'];old=(BASE/'original'/runtime).read_text();new=(BASE/'proposed'/runtime).read_text()
    fragment='        case .trustStatus(_, let status, _, _):\n            // Authorization is upstream diagnostics, not a native grant. Leave\n            // the complete event for Serve.handleTrustStatus below this hook.'
    require(new.replace(fragment,'        case .trustStatus(_, let status, _):')==old,'Runtime has more than the arity/comment correction')
    original=read(__import__('pathlib').Path(c['base'])/'test-coverage.json');current=read(BASE/'test-coverage.json')
    expected=sorted(original['completionLabels']+['authorizationDiagnosticsPreserveDispatchAndNeverOverrideMemberStop()'])
    require(current['completionLabels']==expected and current['testCount']==193 and current['parameterizedCaseStarts']==original['parameterizedCaseStarts'] and current['swiftFilter']==original['swiftFilter'],'Existing192 semantics changed')
    print('PASS: source inverse/AST, exact14111 inventory with two replacements, original192 + one new label; no preparation/compiler/test')
if __name__=='__main__':main()
