from pathlib import Path
import hashlib,json,difflib
HERE=Path(__file__).resolve().parent
ROOT=Path('/Users/developer/DarkbloomDev/d-inference')
RESEARCH=HERE.parent
MEMBER=RESEARCH/'cluster-registered-member-draft-20260915/proposed'
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
rows=[];patch=[]
for p in sorted((HERE/'proposed').rglob('*')):
 if not p.is_file():continue
 rel=p.relative_to(HERE/'proposed').as_posix();original=HERE/'originals'/rel
 base=(MEMBER/rel if (MEMBER/rel).is_file() else ROOT/rel) if original.is_file() else None
 if base is not None:
  assert original.read_bytes()==base.read_bytes(),rel
 else:assert not (ROOT/rel).exists() and not (MEMBER/rel).exists(),rel
 rows.append({'path':rel,'effectiveBasePath':str(base) if base else None,'baseSHA256':sha(base) if base else None,'mainSHA256':sha(ROOT/rel) if (ROOT/rel).is_file() else None,'proposedSHA256':sha(p),'sizeBytes':p.stat().st_size})
 before=original.read_text().splitlines(keepends=True) if original.is_file() else []
 patch+=difflib.unified_diff(before,p.read_text().splitlines(keepends=True),fromfile='a/'+rel if original.is_file() else '/dev/null',tofile='b/'+rel)
(HERE/'integration.json').write_text(json.dumps({'schema':'coordinator_native_pair_source_overlay_v1','mainChanged':False,'memberManifestSHA256':'4ae431c60990ff9e4dfe319b8b5387ac8fb6bffcd54eac0213d3f85ed60ef965','files':rows},indent=2)+'\n')
(HERE/'runtime.patch').write_text(''.join(patch))
paths=list((ROOT/'coordinator/registry').glob('verified_pair*.go'))
paths += [ROOT/p for p in ['coordinator/registry/provider_writer.go','coordinator/registry/provider_capabilities.go','coordinator/attestation/attestation.go','coordinator/api/server_helpers_test.go','coordinator/registry/provider_writer_test.go','libs/darkbloom-cluster/Sources/DarkbloomClusterProtocol/ClusterWorkerEnvelopeValidation.swift','libs/darkbloom-cluster/Sources/DarkbloomClusterProtocol/ClusterWorkerJSON.swift','libs/darkbloom-cluster/Sources/DarkbloomClusterProtocol/ClusterWorkerMessages.swift','provider-swift/Package.swift','go.mod','go.sum']]
paths += [MEMBER/p for p in ['coordinator/protocol/execution_role.go','coordinator/registry/execution_role.go','coordinator/registry/routing_eligibility.go','coordinator/registry/verified_pair_membership.go']]
qualified=RESEARCH/'cluster-native-key-prelude-validation-3-20260916/source/proposed/libs/darkbloom-cluster/Sources/DarkbloomClusterSecurity'
paths += [qualified/p for p in ['ClusterNativeAuthorizationCodec.swift','ClusterNativeAuthorizationTypes.swift','ClusterNativeRecordAuthority.swift']]
paths += [RESEARCH/'cluster-native-pair-authorization-plan-20260916/PLAN.md',RESEARCH/'cluster-native-pair-authorization-plan-20260916/SOURCE-MAP.md',RESEARCH/'cluster-native-key-prelude-validation-3-20260916/checks-1/independent-vector.json']
(HERE/'source-pins.json').write_text(json.dumps({'schema':'native_pair_B_source_dependencies_v1','files':[{'path':str(p),'sha256':sha(p),'sizeBytes':p.stat().st_size} for p in sorted(set(paths))]},indent=2)+'\n')
print(json.dumps({'proposedFiles':len(rows),'replacements':sum(x['baseSHA256'] is not None for x in rows),'dependencyPins':len(set(paths)),'runtimePatchSHA256':sha(HERE/'runtime.patch')}))
