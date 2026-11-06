from pathlib import Path
import datetime,json,shlex,subprocess,time
ROOT=Path(__file__).resolve().parent

def observe(host):
    source='''import json,subprocess
commands={"vm": ["/usr/bin/vm_stat"], "memory": ["/usr/sbin/sysctl","-n","kern.memorystatus_vm_pressure_level","vm.swapusage"], "power": ["/usr/bin/pmset","-g","batt"], "processes": ["/bin/ps","-axo","pid=,comm="]}
result={}
for name,args in commands.items():
 p=subprocess.run(args,check=True,capture_output=True,text=True,timeout=5);assert not p.stderr;result[name]=p.stdout
assert not any(line.split()[-1].endswith("/cluster-inference") or line.split()[-1]=="cluster-inference" for line in result["processes"].splitlines() if line.split())
result["processes"]="No cluster-inference native worker found"
print(json.dumps(result))
'''
    p=subprocess.run(['ssh','-o','BatchMode=yes','-o','ConnectTimeout=8',host,'/usr/bin/python3 -'],input=source,capture_output=True,text=True,check=True,timeout=30)
    assert not p.stderr
    return json.loads(p.stdout)

out=ROOT/'resident-physical-attempt9-resource-preparation-20260915.json'
assert not out.exists()
record={'atUTC':datetime.datetime.now(datetime.timezone.utc).isoformat(),'before':{}}
for host in ['darkbloom-24','darkbloom-48']: record['before'][host]=observe(host)
rows=[[cell.strip().strip('`') for cell in line.strip().strip('|').split('|')] for line in (ROOT.parent/'machines/CREDENTIALS.private.md').read_text().splitlines() if line.startswith('|')]
password=rows[2][[cell.lower() for cell in rows[0]].index('password')]
start=time.monotonic()
p=subprocess.run(['ssh','-T','-o','BatchMode=yes','darkbloom-24',shlex.join(['/usr/bin/sudo','-k','-S','-p','','/usr/sbin/purge'])],input=password+'\n',capture_output=True,text=True,timeout=40)
record['purge']={'host':'darkbloom-24','elapsedSeconds':time.monotonic()-start,'exitCode':p.returncode,'stdout':p.stdout.replace(password,'[REDACTED]'),'stderr':p.stderr.replace(password,'[REDACTED]')}
record['after']={host:observe(host) for host in ['darkbloom-24','darkbloom-48']}
with out.open('x') as f: json.dump(record,f,indent=2);f.write('\n')
assert p.returncode==0 and not p.stdout and not p.stderr
print(json.dumps({'receipt':str(out),'purgeExitCode':p.returncode,'bothWithoutNativeWorkers':True}))
