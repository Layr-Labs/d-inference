import hashlib,json,pathlib,subprocess
base=pathlib.Path("/Users/gaj/.codex/worktrees/kv-gemma-native-packets/d-inference/docs/reports/evidence/native-kv-packets-2026-10-09")
out=pathlib.Path("/tmp/kv-native-codec-probe")
results=[]
for model in ["gemma","gpt"]:
 receipt=json.loads((base/model/"receipt.json").read_text())
 for row in receipt["records"]:
  if row["role"] not in ["keys","values"]:continue
  f=base/model/row["file"]
  sha=hashlib.sha256(f.read_bytes()).hexdigest()
  if sha!=row["sha256"]:raise RuntimeError("input SHA mismatch")
  width={"bfloat16":2,"float16":2,"float32":4}[row["dtype"]]
  r=json.loads(subprocess.check_output([str(out/"codec-probe"),str(f),str(width)],text=True))
  if not r["bitExact"] or r["inputSHA256"]!=sha or r["nativeBytes"]!=row["bytes"]:raise RuntimeError("invalid codec receipt")
  results.append(dict(r,model=model,phase=row["phase"],layer=row["layer"],role=row["role"],dtype=row["dtype"],shape=row["shape"],modelAggregateSHA256=receipt["model_aggregate_sha256"]))
summary=[]
for model in ["gemma","gpt"]:
 rows=[r for r in results if r["model"]==model]
 n=sum(r["nativeBytes"] for r in rows);e=sum(r["encodedFrameBytes"] for r in rows)
 summary.append(dict(model=model,packets=len(rows),nativeBytes=n,encodedFrameBytes=e,savingFraction=1-e/n,allBitExact=all(r["bitExact"] for r in rows)))
(out/"results.json").write_text(json.dumps(results,indent=2,sort_keys=True)+"\n")
(out/"summary.json").write_text(json.dumps(summary,indent=2,sort_keys=True)+"\n")
print(json.dumps(summary,indent=2))
