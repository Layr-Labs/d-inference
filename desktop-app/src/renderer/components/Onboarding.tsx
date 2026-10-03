import { useState } from 'react';
import type { BackendState } from '../useBackend';
import { External } from './UI';
import { OnboardingIntro } from './onboarding/OnboardingIntro';
import { OnboardingSteps } from './onboarding/OnboardingSteps';
import { ScanStep } from './onboarding/ScanStep';
import { scanTiming } from './onboarding/scanScript';
import { StartServing } from './onboarding/StartServing';
import { useMacScan } from './onboarding/useMacScan';
import { Welcome } from './onboarding/Welcome';

type Step = 'welcome' | 'scan' | 'start';

export function Onboarding({ backend, done }: { backend: BackendState; done: () => void }) {
  const [step, setStep] = useState<Step>('welcome');
  const scan = useMacScan(backend, step === 'scan', () => setStep('start'));
  const joined = step === 'start' || (scan.settled && scan.result?.verdict === 'eligible');
  const leaving = step === 'scan' && scan.frame.phase === 'leaving';
  const grid =
    step === 'welcome'
      ? 'idle'
      : joined
        ? 'joined'
        : scan.blocked || scan.settled
          ? 'idle'
          : 'scanning';
  return (
    <div className="onboarding">
      <img src="./brand/logo.svg" alt="Darkbloom" className="onboarding-logo" />
      <div className="onboarding-layout">
        <OnboardingIntro grid={grid} />
        <section className="onboarding-form">
          <OnboardingSteps current={step === 'start' ? 1 : 0} />
          <div
            className={`onboarding-step ${leaving ? 'leaving' : ''}`}
            style={leaving ? { animationDuration: `${scanTiming.exitMs}ms` } : undefined}
            key={step}
          >
            {step === 'welcome' && <Welcome start={() => setStep('scan')} />}
            {step === 'scan' && (
              <ScanStep
                backend={backend}
                scan={scan}
                proceed={() => setStep('start')}
                explore={done}
              />
            )}
            {step === 'start' && backend.state && (
              <StartServing backend={backend} snapshot={backend.state} done={done} />
            )}
          </div>
        </section>
      </div>
      <footer>
        <span>Powered by your Mac. Built by people.</span>
        <External target="docs">Read the guide</External>
      </footer>
    </div>
  );
}
