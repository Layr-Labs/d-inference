from pathlib import Path
import hashlib,importlib.util,json,os,shlex,stat,subprocess,sys,time
ROOT=Path(__file__).resolve().parent
SOURCE=ROOT.parent/'qwen27b-matched-short-cohort-draft-20260916/physical-source/prepare_resources.py'
assert hashlib.sha256(SOURCE.read_bytes()).hexdigest()=='f4477ad6d5b0c046c0a8b10978263c35b8d36dce79c3ee8b8a06ddae906907e6'
spec=importlib.util.spec_from_file_location('retained_resource_preparation',SOURCE);m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
case,=sys.argv[1:];assert case in ('serial','lookahead')
os.umask(0o077);out=ROOT/(case+'-resource-preparation-1');out.mkdir(mode=0o700)
p=ROOT.parent.parent/'machines/CREDENTIALS.private.md';s=p.lstat();assert stat.S_ISREG(s.st_mode) and s.st_uid==os.getuid() and stat.S_IMODE(s.st_mode)==0o600
rows=[[c.strip().strip('`') for c in line.strip().strip('|').split('|')] for line in p.read_text().splitlines() if line.startswith('|')]
secret=(rows[2][[c.lower() for c in rows[0]].index('password')]+'\n').encode()
for rank,host in enumerate(['darkbloom-24','darkbloom-48']):
 command=m.SSH+['-S','none',host,shlex.join(['/usr/bin/python3','-B','-c',m.REMOTE])]
 start=time.monotonic();record={'host':host,'case':case,'remoteScriptSHA256':hashlib.sha256(m.REMOTE.encode()).hexdigest(),'passed':False}
 try:
  result=subprocess.run(command,input=secret,capture_output=True,timeout=50)
  (out/f'rank{rank}.stdout').write_bytes(result.stdout);(out/f'rank{rank}.stderr').write_bytes(result.stderr)
  record.update(exitCode=result.returncode,stdoutSHA256=hashlib.sha256(result.stdout).hexdigest(),stderrSHA256=hashlib.sha256(result.stderr).hexdigest())
  assert result.returncode==0 and not result.stderr and len(result.stdout)<=131072
  value=json.loads(result.stdout);assert value['passed'] and value['journalUnchanged'] and value['reaped'] and value['groupAbsent']
  record.update(passed=True,beforeFreeBytes=value['before']['actualFreeBytes'],afterFreeBytes=value['after']['actualFreeBytes'])
 finally:
  record['elapsedSeconds']=time.monotonic()-start;(out/f'rank{rank}.receipt.json').write_text(json.dumps(record,indent=2)+'\n')
 print(json.dumps(record),flush=True)
