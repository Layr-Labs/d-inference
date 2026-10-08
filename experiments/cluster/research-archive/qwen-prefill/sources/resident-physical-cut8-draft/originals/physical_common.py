"""Small bounded records and source checks shared by this two-peer experiment."""
import hashlib
import json
import os
from pathlib import Path
import re
import stat

from binding_inputs import snapshot
from solo_reference import REFERENCE_PINS
from stage_checks.common import canonical, exact, integer, parse, require, sha
from stage_checks.long_profile import ARTIFACT, CONFIGURATION, REQUIRED_ENVIRONMENT
from worker_contract import open_command

SCHEMA='resident_physical_9b_v1'
JOB_SCHEMA='resident_physical_9b_rank_job_v1'


def write_new(path, raw):
    with Path(path).open('xb') as out:
        os.fchmod(out.fileno(),0o600);out.write(raw);out.flush();os.fsync(out.fileno())


def write_json(path, value):write_new(path,canonical(value)+b'\n')


def fields(value,names,label):
    require(type(value) is dict and set(value)==set(names.split()),label+' fields differ')


def path(value):
    require(type(value) is str and re.fullmatch(r'/(?:[A-Za-z0-9_.-]+/)*[A-Za-z0-9_.-]+',value)
            and all(p not in ('.','..') for p in Path(value).parts),'Expected normalized absolute path')
    return Path(value)


def host(value):
    require(type(value) is str and re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.-]{0,127}',value),'Expected SSH config alias')
    return value


def endpoint(value):
    require(type(value) is str and re.fullmatch(r'(?:[0-9]+\.){3}[0-9]+:[0-9]+',value),'Expected IPv4:port')
    address,port=value.split(':');numbers=address.split('.')
    require(all(str(int(x))==x and 0<=int(x)<=255 for x in numbers)
            and 0<int(numbers[0])<224 and str(int(port))==port and 1<=int(port)<=65535,'Invalid coordinator')
    return value


def read_plan(value):
    fields(value,'schema cohort_id launcher_path native_sha256 package_sha256 bundle_sha256 package_members coordinator devices peers','plan')
    require(value['schema']==SCHEMA,'Wrong physical plan schema')
    # Validate exact cohort-label contract without minting real run epochs here.
    open_command(value['cohort_id'],[dict(request_id=value['cohort_id']+suffix,epoch=('%032x'%i))
        for i,suffix in enumerate((':warmup:0',':measured:0',':measured:1',':measured:2'),1)])
    path(value['launcher_path']);endpoint(value['coordinator'])
    for key in ('native_sha256','package_sha256','bundle_sha256'):sha(value[key])
    integer(value['package_members'],1,4096)
    require(type(value['devices']) is list and len(value['devices'])==2,'Two devices required')
    for device in value['devices']:
        require(type(device) is str and re.fullmatch(r'[A-Za-z0-9_.-]{1,63}',device),'Invalid RDMA device name')
    require(type(value['peers']) is list and len(value['peers'])==2,'Two ordered peers required')
    for peer in value['peers']:
        fields(peer,'host deployment model_dir run_dir','peer');host(peer['host'])
        deployment,model,run=(path(peer[k]) for k in ('deployment','model_dir','run_dir'))
        launcher=path(value['launcher_path'])
        require(all(run!=p and not run.is_relative_to(p) and not p.is_relative_to(run)
            for p in (deployment,model,launcher)),'Run path overlaps deployment/model/launcher')
    require(value['peers'][0]['host']!=value['peers'][1]['host'],'Two distinct SSH peers required')
    return parse(canonical(value))


def make_jobs(plan,declared):
    opened=open_command(plan['cohort_id'],declared)
    matrix=[[None,plan['devices'][0]],[plan['devices'][1],None]]
    return [dict(schema=JOB_SCHEMA,rank=rank,peer=peer,launcher_path=plan['launcher_path'],
        native_sha256=plan['native_sha256'],package_sha256=plan['package_sha256'],bundle_sha256=plan['bundle_sha256'],
        package_members=plan['package_members'],coordinator=plan['coordinator'],matrix=matrix,opened=opened,
        cut=12,policy='serial_v1',native_seconds=300,supervisor_seconds=315)
        for rank,peer in enumerate(plan['peers'])]


def validate_job(job):
    fields(job,'schema rank peer launcher_path native_sha256 package_sha256 bundle_sha256 package_members coordinator matrix opened cut policy native_seconds supervisor_seconds','job')
    integer(job['rank'],0,1)
    require(job['schema']==JOB_SCHEMA and type(job['cut']) is int and job['cut']==12 and job['policy']=='serial_v1'
        and type(job['native_seconds']) is int and job['native_seconds']==300
        and type(job['supervisor_seconds']) is int and job['supervisor_seconds']==315,'Unsupported physical job')
    opened=job['opened'];fields(opened,'schema type cohort_id requests','open')
    exact(opened,open_command(opened['cohort_id'],opened['requests']),'Invalid open')
    matrix=job['matrix'];require(type(matrix) is list and len(matrix)==2 and all(type(x) is list and len(x)==2 for x in matrix)
        and matrix[0][0] is None and matrix[1][1] is None,'Invalid device matrix')
    for device in (matrix[0][1],matrix[1][0]):
        require(type(device) is str and re.fullmatch(r'[A-Za-z0-9_.-]{1,63}',device),'Invalid device')
    fields(job['peer'],'host deployment model_dir run_dir','peer');host(job['peer']['host'])
    for key in ('deployment','model_dir','run_dir'):path(job['peer'][key])
    path(job['launcher_path']);endpoint(job['coordinator'])
    for key in ('native_sha256','package_sha256','bundle_sha256'):sha(job[key])
    integer(job['package_members'],1,4096)
    run=path(job['peer']['run_dir'])
    for parent in (path(job['peer']['deployment']),path(job['peer']['model_dir']),path(job['launcher_path'])):
        require(not run.is_relative_to(parent) and not parent.is_relative_to(run),'Run overlaps input')
    return job


class Pins:
    def __init__(self):self.saved=[]
    def read(self,filename,cap,wanted=None,keep=True,empty=False):
        value=snapshot(filename,cap,keep=keep,empty=empty)
        require(wanted is None or value['sha256']==wanted,'File pin differs: '+str(filename))
        self.saved.append((Path(filename),cap,empty,{k:v for k,v in value.items() if k!='raw'}))
        return value
    def recheck(self):
        for filename,cap,empty,before in self.saved:
            after=snapshot(filename,cap,keep=False,empty=empty)
            exact({k:v for k,v in after.items() if k!='raw'},before,'Input/source changed: '+str(filename))


def verify_launcher(directory,wanted,pins):
    directory=path(str(directory));raw=pins.read(directory/'manifest.json',1024**2,sha(wanted))['raw']
    manifest=parse(raw);entries=manifest['files'];require(type(entries) is list and 1<=len(entries)<=100,'Launcher member bound')
    seen=set()
    for row in entries:
        name=row['path'];relative=Path(name)
        require(type(name) is str and not relative.is_absolute() and '..' not in relative.parts and name not in seen,'Launcher member path')
        item=pins.read(directory/relative,32*1024**2,row['sha256'],keep=False,empty=True)
        require(item['size_bytes']==row['size_bytes'],'Launcher member size differs');seen.add(name)
    return hashlib.sha256(raw).hexdigest()


def verify_deployment(job,pins):
    root=path(job['peer']['deployment']);require(root.is_dir() and root.resolve()==root,'Real deployment required')
    raw=pins.read(root/'manifest.json',1024**2,job['package_sha256'])['raw'];manifest=parse(raw)
    require(manifest['native_sha256']==job['native_sha256'] and len(manifest['files'])==job['package_members'],'Native package identity differs')
    seen=set()
    for row in manifest['files']:
        name=row['path'];relative=Path(name)
        require(type(name) is str and not relative.is_absolute() and '..' not in relative.parts and name not in seen,'Package path differs')
        target=root/relative;require(all(not p.is_symlink() for p in target.parents),'Package symlink ancestor')
        item=pins.read(target,256*1024**2,row['sha256'],keep=False,empty=True)
        require(item['size_bytes']==row['size_bytes'],'Package size differs');seen.add(name)
    bundle=root/'bundle';bm=parse(pins.read(bundle/'bundle.json',1024**2,job['bundle_sha256'])['raw'])
    require(len(bm['files'])==5,'Five bundled resources required')
    actual=set()
    for directory,dirs,files in os.walk(bundle,followlinks=False):
        for p in [Path(directory)]+[Path(directory)/n for n in dirs+files]:
            st=p.lstat();require(st.st_uid==os.geteuid() and not stat.S_ISLNK(st.st_mode),'Bundle ownership/link differs')
            if stat.S_ISDIR(st.st_mode):require(st.st_mode & 0o022==0,'Externally writable directory')
            else:
                require(stat.S_ISREG(st.st_mode) and st.st_mode & 0o222==0,'Read-only regular bundle required')
                actual.add(p.relative_to(bundle).as_posix())
    require(actual=={'bundle.json'}|{r['path'] for r in bm['files']},'Bundle members differ')
    require(next(x['sha256'] for x in bm['files'] if x['path']=='cluster-inference')==job['native_sha256'],'Native bundle pin differs')
    require((bundle/'cluster-inference').stat().st_mode & stat.S_IXUSR,'Native is not executable')
    model=path(job['peer']['model_dir']);require(model.is_dir() and model.resolve()==model,'Real model directory required')
    pins.read(model/'config.json',1024**2,CONFIGURATION)
    pins.read(model/'manifest.json',4*1024**2,'4f2735026cc7b40ee2c886ee53fb8755816c0001c4c69c141a61d5f56ff22aa4')
    return dict(nativeSHA256=job['native_sha256'],packageSHA256=job['package_sha256'],bundleSHA256=job['bundle_sha256'],
        sourceSnapshotSHA256=manifest['source_snapshot_sha256'],packageMembers=len(manifest['files']),modelPayloadVerifiedByPython=False)


def native_spec(job):
    run=path(job['peer']['run_dir']);bundle=path(job['peer']['deployment'])/'bundle'
    env=dict(PATH='/usr/bin:/bin:/usr/sbin:/sbin',LANG='C',**REQUIRED_ENVIRONMENT,
        JACCL_RANK=str(job['rank']),JACCL_IBV_DEVICES=str(run/'matrix.json'),JACCL_COORDINATOR=job['coordinator'])
    argv=(str(bundle/'cluster-inference'),'--mode','qwen-resident-benchmark-worker','--role','rank',
        '--transport','jaccl','--model-dir',job['peer']['model_dir'],'--artifact-aggregate-sha256',ARTIFACT,
        '--tokens-file',str(run/'prompt.json'),'--long-prompt-sha256',REFERENCE_PINS['prompt.json'],
        '--stage-prefill-policy','serial_v1','--stage-cut','12','--timeout-seconds','300')
    return argv,env,bundle
