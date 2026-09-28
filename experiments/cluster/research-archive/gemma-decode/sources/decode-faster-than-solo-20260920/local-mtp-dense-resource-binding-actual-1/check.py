from pathlib import Path
import copy,importlib.util,json
base=Path('/Users/developer/DarkbloomDev/cluster-research/decode-faster-than-solo-20260920')
file=base/'local-mtp-dense-resource-binding-correction/prepare.py'
spec=importlib.util.spec_from_file_location('resource_correction',file);module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
projected,template,bindings=module.verify()
build=base/'build/dense-execution-build-1/receipt.json';sources=base/'build/dense-execution-composition-1/sources.json'
actual=module.bind(build,sources,template,bindings)
assert actual['nativeSHA256']=='5db4b221bd152dea66b816bc627aa689e45fab34151848bb7689fcc07d96f154'
resources=json.loads(build.read_bytes())['resources']
for label,bad in [('changed-hash',copy.deepcopy(resources)),('duplicate-name',copy.deepcopy(resources))]:
 if label=='changed-hash':bad[0]['sha256']='0'*64
 else:bad[1]=copy.deepcopy(bad[0])
 try:module.bind_resources(bad,template['resources'])
 except AssertionError:pass
 else:raise AssertionError(label+' accepted')
print(json.dumps(dict(status='passed',groups=3,actualBuildJoined=True,changedHashRefused=True,duplicateNameRefused=True,nativeSHA256=actual['nativeSHA256'],materialized=False,nativeExecuted=False)))
