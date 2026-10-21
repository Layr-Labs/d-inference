#!/usr/bin/env python3
"""Verify existing public model bytes against the coordinator manifest; do not mutate the source cache."""
import argparse, hashlib, json, os
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument("--hub",default=str(Path.home()/".cache/huggingface/hub"));p.add_argument("--manifests",default=str(Path(__file__).parent/"manifests"));p.add_argument("--output",required=True);p.add_argument("--models",nargs="*");a=p.parse_args()
hub=Path(a.hub);out=Path(a.output);out.mkdir(parents=True,exist_ok=True)
files={}
for model in hub.glob("models--*"):
 for snapshot in model.glob("snapshots/*"):
  if snapshot.is_dir():
   for f in snapshot.iterdir():
    if f.is_file():
     st=f.stat();files.setdefault((f.name,st.st_size),[]).append(f)
hashes={};records=[]
for mp in sorted(Path(a.manifests).glob("*.json")):
 m=json.loads(mp.read_text());mid=m["model_id"]
 if a.models and mid not in a.models:continue
 target=out/mid.replace("/","--");target.mkdir(exist_ok=True)
 record={"model_id":mid,"aggregate_sha256":m["aggregate_sha256"],"directory":str(target),"files":[],"complete":True}
 for item in m["files"]:
  name=item["path"];wanted=item["sha256"];match=None
  for f in files.get((Path(name).name,item["size_bytes"]),[]):
   st=f.stat();key=(st.st_dev,st.st_ino,st.st_size)
   if key not in hashes:
    h=hashlib.sha256()
    with f.open("rb") as fp:
     for chunk in iter(lambda:fp.read(8<<20),b""):h.update(chunk)
    hashes[key]=h.hexdigest()
   if hashes[key]==wanted:match=f;break
  entry={"path":name,"size_bytes":item["size_bytes"],"sha256":wanted,"matched":str(match) if match else None}
  if match:
   dest=target/name;dest.parent.mkdir(parents=True,exist_ok=True)
   if dest.exists():
    if not os.path.samefile(dest,match):raise RuntimeError("owned destination differs: "+str(dest))
   else:os.link(match.resolve(),dest)
  else:record["complete"]=False
  record["files"].append(entry)
  print(mid,name,"verified" if match else "MISSING",flush=True)
 records.append(record)
 (out/"verification.json").write_text(json.dumps(records,indent=2)+"\n")
