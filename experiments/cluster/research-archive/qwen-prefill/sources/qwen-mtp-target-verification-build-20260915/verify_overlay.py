"""No-execution inverse check of ordinary/proposal source preservation."""
from pathlib import Path
import hashlib,json
BASE=Path(__file__).resolve().parent
REL=Path('libs/darkbloom-cluster/Sources/DarkbloomClusterRuntime')

def main():
    current=BASE/'workspace'/REL
    prior=BASE/'draft/originals'/REL
    core=(current/'CBv2OwnedRequestState.swift').read_text()
    core=core.replace('    private var verification: CBv2TargetVerification?\n','')
    core=core.replace('evaluation == nil, verification == nil else','evaluation == nil else')
    a=core.index('    func beginVerification(');b=core.index('    func validateState(',a);core=core[:a]+core[b:]
    core=core.replace('        do { try verification?.discard() } catch { cleanupError = error }\n        verification = nil\n','')
    core=core.replace('do { try evaluation.rollback() } catch { cleanupError = cleanupError ?? error }','do { try evaluation.rollback() } catch { cleanupError = error }')
    if core!=(prior/'CBv2OwnedRequestState.swift').read_text():raise RuntimeError('Ordinary Core inverse differs')
    session=(current/'QwenLayerStageSession.swift').read_text()
    session=session.replace('    private var verification: QwenTargetVerificationExecution?\n    private var usedVerificationRounds = Set<UUID>()\n','')
    a=session.index('    /// Private opt-in seam;');b=session.index('    private func perform(',a);session=session[:a]+session[b:]
    session=session.replace('        defer { verification?.discardOutputs(); verification = nil }\n','')
    if session!=(prior/'QwenLayerStageSession.swift').read_text():raise RuntimeError('MTP/ordinary Session inverse differs')
    names=['QwenResidentMTPRequest.swift','QwenResidentMTPProposalControl.swift','QwenLayerStageGenerationDriver.swift','QwenLayerStageMTPProbe.swift','QwenResidentMTPProbeRuntime.swift','QwenResidentRuntime.swift','QwenResidentRuntime+Load.swift']
    old=BASE.parent/'qwen-resident-mtp-registered-probe-native-build-20260915/workspace'/REL
    for name in names:
        if (current/name).read_bytes()!=(old/name).read_bytes():raise RuntimeError('Unowned proposal/probe source changed')
    print(json.dumps(dict(ordinaryCoreInverse=True,ordinaryAndCorrectedMTPSessionInverse=True,unchangedProposalProbeAndFacadeFiles=names,compilerOrNativeExecution=False),indent=2))
if __name__=='__main__':main()
