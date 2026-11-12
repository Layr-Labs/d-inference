"""Separate recorded runtime profile identity from a particular request's evidence."""
from copy import deepcopy
from binding_common import canonical, sha
from binding_manifests import semantic_identity
from binding_oracle import PINS
from binding_pins import ARITHMETIC_ENVIRONMENT, PRIVATE_SOURCE_PINS, PROFILE_POLICY


def result(inputs, parent, source, sources, bundle, runtime, numerical, observations, counts):
    files = semantic_identity(source, sources, bundle)
    definition = dict(policy=PROFILE_POLICY, registeredProfile=parent['registeredProfile'],
                      artifactSHA256=parent['expectedIdentity']['artifact'],
                      configurationSHA256=parent['expectedIdentity']['configuration'],
                      canonicalInventorySHA256=numerical['canonicalInventorySHA256'],
                      sourceParameterLayoutSHA256=numerical['sourceParameterLayoutSHA256'],
                      nativeModelProfileFingerprint=parent['profileFingerprint'],
                      planFingerprint=parent['planFingerprint'], arithmeticEnvironment=ARITHMETIC_ENVIRONMENT,
                      requiredAbsentNames=['MLX_METAL_GPU_ARCH', 'MLX_SDPA_BLOCKS'],
                      dispatchPolicy='actual_metal_device', naxAvailability='unknown',
                      runtime={name:runtime['runtime'][name] for name in (
                          'operatingSystemVersion', 'deviceArchitecture', 'deviceMemoryBytes',
                          'maximumBufferBytes', 'recommendedWorkingSetBytes')}, **files)
    profile_sha = sha(b'private-short-recorded-runtime-profile-v1\n' + canonical(definition))
    bindings = dict(packetSHA256=inputs.packet_snapshot['sha256'], files=inputs.metadata(),
                    recordedRuntimeProfileSHA256=profile_sha, nativePID=parent['nativePID'],
                    runtime=runtime, parentPrivateSourceSHA256=PRIVATE_SOURCE_PINS,
                    numericalOracleSourceSHA256=PINS, recordedRequestFingerprint=parent['recordedRequestFingerprint'],
                    referenceAdmissionFingerprint=parent['referenceAdmissionFingerprint'],
                    baselineEvidenceSHA256=numerical['baselineEvidenceSHA256'])
    # Callers may annotate a receipt. Never expose mutable references to the
    # frozen policy/oracle pin dictionaries used by subsequent audits.
    return deepcopy(dict(kind='private_short_execution_binding_audit', schemaVersion=1, passed=True,
                profileDefinition=definition, recordedRuntimeProfileSHA256=profile_sha,
                executionEvidenceSHA256=sha(b'private-short-execution-evidence-v1\n' + canonical(bindings)),
                bindings=bindings, retainedMemberCounts=counts, parentObservations=observations,
                freshNumericalReplay=numerical, suppliedEvidenceConsistencyChecked=True,
                numericalAuditReplayed=True, originalNumericalReceiptMatched=True,
                retainedSourceAndBundleMemberBytesVerified=True, historicalPathsFollowed=False,
                historicalNativeExecutionIndependentlyVerified=False, parentProcessExitIndependentlyVerified=False,
                sourceToBinaryBuildVerified=False, loadedMetallibIndependentlyVerified=False,
                originalBundleTreeOwnershipVerified=False, completeProcessEnvironmentVerified=False,
                hardwareIdentityAttested=False, physicalDeviceIdentity=None, gpuCoreCount=None,
                naxEligibilityQualified=False, hardwareSpecificQualification=False,
                nativeExecutionPerformed=False, weightTensorValuesRead=False,
                physicalTwoMachineExecution=False, executionAdmission=False,
                providerEligibilityEstablished=False, throughputQualification=False))
