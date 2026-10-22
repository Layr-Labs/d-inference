from pathlib import Path
import ast,hashlib,json,os,sys
ROOT=Path(__file__).resolve().parent;RESEARCH=ROOT.parent
BASE=RESEARCH/'gemma4-short-physical-draft-20260916'
CORRECTION=RESEARCH/'gemma4-short-physical-terminal-binding-correction-20260916'
OUTPUT=RESEARCH/'gemma4-short-physical-reviewed-source-20260917'
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
def verify():
 for folder,wanted,count in [(BASE,'26fe8d9d4601e3211d2db8444a1af581c19ab61f26f623da918c5da0bc341aee',74),(CORRECTION,'3cd4af0b02e012a1470060a524e321083048329feea844f7998681c600bc84ee',9)]:
  assert sha(folder/'manifest.json')==wanted;rows=json.loads((folder/'manifest.json').read_bytes())['files'];assert len(rows)==count
  for row in rows:
   p=folder/row['path'];assert p.stat().st_size==row['bytes'] and sha(p)==row['sha256']
   if p.suffix=='.py':ast.parse(p.read_text())
 p=RESEARCH/'gemma4-short-physical-source-review-20260916/source-review.json'
 assert sha(p)=='37876ef7d269b7adc496d1a82000e3a173f82a7954c74f02da7f38b4cd2f9d82'
 return True
verify();sys.path.insert(0,str(BASE));from check_process import run_owned
os.umask(0o077);out=ROOT/'physical-source-qualification-1';out.mkdir(mode=0o700)
record={'passed':False,'steps':[],'original14ControlsRerun':False,'nativeOrCompilerOrRemoteExecuted':False}
try:
 record['steps'].append(run_owned([sys.executable,'-B',str(CORRECTION/'Tests/test_terminal_binding.py')],out,'terminal-binding',30))
 record['steps'].append(run_owned([sys.executable,'-B',str(CORRECTION/'prepare.py'),'--output',str(OUTPUT)],out,'source-composition',60))
 verify();composed=json.loads((OUTPUT/'manifest.json').read_bytes())
 for row in composed['files']:
  p=OUTPUT/row['path'];assert p.stat().st_size==row['bytes'] and sha(p)==row['sha256']
 record.update(passed=True,composedSource=str(OUTPUT),composedManifestSHA256=sha(OUTPUT/'manifest.json'),composedMembers=len(composed['files']))
finally:(out/'receipt.json').write_text(json.dumps(record,indent=2)+'\n')
print(json.dumps(record),flush=True)
