import { ArrowRight } from 'lucide-react';
import { useEffect, useRef, useState } from 'react';
import type { BackendState } from '../useBackend';
import { External } from './UI';
import { OnboardingIntro } from './onboarding/OnboardingIntro';
import { LinkStep } from './onboarding/LinkStep';
import { OnboardingSteps } from './onboarding/OnboardingSteps';
import { RuntimeSetup } from './onboarding/RuntimeSetup';
import { ScanStep } from './onboarding/ScanStep';
import { scanTiming } from './onboarding/scanScript';
import { StartServing } from './onboarding/StartServing';
import { useAccountLink } from './onboarding/useAccountLink';
import { useMacScan } from './onboarding/useMacScan';
import { Welcome } from './onboarding/Welcome';
import { useFocusRecovery } from '../useFocusRecovery';

type Step = 'install' | 'welcome' | 'link' | 'scan' | 'start';

// The Mac is checked before an account is linked, so an ineligible Mac is never asked to link.
const stepIndex: Record<Step, number> = { install: 0, welcome: 1, scan: 1, link: 2, start: 3 };

// Statuses in which the CLI is absent, broken or being (re)installed at the user's request. A
// brief reconnect once a snapshot has arrived keeps the current step instead.
const unavailable: BackendState['status']['state'][] = [
  'missing',
  'error',
  'incompatible',
  'installing',
];

export function Onboarding({ backend, done }: { backend: BackendState; done: () => void }) {
  // Every later step needs the Darkbloom CLI, so the install step stands in for them until it is
  // connected with a snapshot.
  const ready = !!backend.state && !unavailable.includes(backend.status.state);
  const [step, setStep] = useState<Step>(ready ? 'welcome' : 'install');
  // Set once the install step has offered an install, repair or update (or shown one the user
  // started): finishing it then goes straight on to the check, not back to the welcome view.
  const [installed, setInstalled] = useState(false);
  // Set once the check has passed (or the user continued past an unconfirmed one). Linking then
  // leads to the start page; starting without a linked account sends people back to link it.
  const [checked, setChecked] = useState(false);
  const linked = !!backend.state?.linked;
  if (!ready && !installed && unavailable.includes(backend.status.state)) setInstalled(true);
  if (step === 'install' && ready) setStep(installed ? 'scan' : 'welcome');
  if (step === 'link' && ready && linked) setStep(checked ? 'start' : 'scan');
  const view: Step = ready ? step : 'install';
  // After the check, an already linked Mac skips linking.
  const afterCheck = () => {
    setChecked(true);
    setStep(linked ? 'start' : 'link');
  };
  const scan = useMacScan(backend, view === 'scan', afterCheck);
  const link = useAccountLink(backend);
  const leave = () => {
    link.cancel();
    done();
  };
  // When the CLI becomes ready, focus moves to the heading of the step that replaces the
  // install step, so keyboard and screen reader users start from the new page.
  const stepElement = useRef<HTMLDivElement>(null);
  const previousView = useRef(view);
  useEffect(() => {
    const from = previousView.current;
    previousView.current = view;
    if (from !== 'install' || view === 'install') return;
    const heading = stepElement.current?.querySelector<HTMLElement>('h2');
    heading?.setAttribute('tabindex', '-1');
    heading?.focus();
  }, [view]);
  // A checked Mac keeps its place in the grid while it links, then starts.
  const joined =
    view === 'start' ||
    (view === 'link' && checked) ||
    (scan.settled && scan.result?.verdict === 'eligible');
  const leaving = view === 'scan' && scan.frame.phase === 'leaving';
  useFocusRecovery(view, () => document.querySelector<HTMLElement>('.onboarding-step h2'));
  const grid =
    view === 'install' || view === 'welcome'
      ? 'idle'
      : joined
        ? 'joined'
        : scan.settled
          ? 'idle'
          : 'scanning';
  return (
    <div className="onboarding">
      <img src="./brand/logo.svg" alt="Darkbloom" className="onboarding-logo" />
      <div className="onboarding-layout">
        <OnboardingIntro grid={grid} />
        <section className="onboarding-form">
          <div className="onboarding-progress">
            <OnboardingSteps current={stepIndex[view]} linked={linked} />
            {/* Setup can be left from any step once there is a dashboard to open. */}
            {backend.state && (
              <button className="text-link" onClick={leave}>
                Explore the app first <ArrowRight size={13} />
              </button>
            )}
          </div>
          <div
            ref={stepElement}
            className={`onboarding-step ${leaving ? 'leaving' : ''}`}
            style={leaving ? { animationDuration: `${scanTiming.exitMs}ms` } : undefined}
            key={view}
          >
            {view === 'install' && <RuntimeSetup backend={backend} />}
            {view === 'welcome' && <Welcome linked={linked} start={() => setStep('scan')} />}
            {view === 'link' && <LinkStep backend={backend} link={link} />}
            {view === 'scan' && (
              <ScanStep
                backend={backend}
                scan={scan}
                next={linked ? 'start serving' : 'link your account'}
                proceed={afterCheck}
                explore={leave}
              />
            )}
            {view === 'start' && backend.state && (
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
