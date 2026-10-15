import { ArrowRight } from 'lucide-react';
import { useState } from 'react';
import type { BackendState } from '../useBackend';
import { External } from './UI';
import { OnboardingIntro } from './onboarding/OnboardingIntro';
import { LinkStep } from './onboarding/LinkStep';
import { OnboardingSteps } from './onboarding/OnboardingSteps';
import { ScanStep } from './onboarding/ScanStep';
import { scanTiming } from './onboarding/scanScript';
import { StartServing } from './onboarding/StartServing';
import { useAccountLink } from './onboarding/useAccountLink';
import { useMacScan } from './onboarding/useMacScan';
import { Welcome } from './onboarding/Welcome';

type Step = 'welcome' | 'link' | 'scan' | 'start';

const stepIndex: Record<Step, number> = { welcome: 0, link: 0, scan: 1, start: 2 };

export function Onboarding({ backend, done }: { backend: BackendState; done: () => void }) {
  const [step, setStep] = useState<Step>('welcome');
  // Starting without a linked account sends people back to link it, then on to the start page
  // again once the check has passed.
  const [checked, setChecked] = useState(false);
  const linked = !!backend.state?.linked;
  if (step === 'link' && linked) setStep(checked ? 'start' : 'scan');
  const toStart = () => {
    setChecked(true);
    setStep('start');
  };
  const scan = useMacScan(backend, step === 'scan', toStart);
  const link = useAccountLink(backend);
  const leave = () => {
    link.cancel();
    done();
  };
  const joined = step === 'start' || (scan.settled && scan.result?.verdict === 'eligible');
  const leaving = step === 'scan' && scan.frame.phase === 'leaving';
  const grid =
    step === 'welcome' || step === 'link'
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
          <div className="onboarding-progress">
            <OnboardingSteps
              current={step === 'welcome' && linked ? 1 : stepIndex[step]}
              linked={linked}
            />
            {/* Setup can be left from any step once there is a dashboard to open. */}
            {backend.state && (
              <button className="text-link" onClick={leave}>
                Explore the app first <ArrowRight size={13} />
              </button>
            )}
          </div>
          <div
            className={`onboarding-step ${leaving ? 'leaving' : ''}`}
            style={leaving ? { animationDuration: `${scanTiming.exitMs}ms` } : undefined}
            key={step}
          >
            {step === 'welcome' && <Welcome linked={linked} start={() => setStep('link')} />}
            {step === 'link' && <LinkStep backend={backend} scan={scan} link={link} />}
            {step === 'scan' && (
              <ScanStep backend={backend} scan={scan} proceed={toStart} explore={leave} />
            )}
            {step === 'start' && backend.state && (
              <StartServing
                backend={backend}
                snapshot={backend.state}
                link={() => setStep('link')}
                done={done}
              />
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
