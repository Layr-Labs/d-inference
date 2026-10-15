import type { BackendState } from '../useBackend';
import { OnboardingIntro } from './onboarding/OnboardingIntro';
import { RuntimeSetup } from './onboarding/RuntimeSetup';
import { unreachable } from './onboarding/useMacScan';

/**
 * Shown to returning users until the first snapshot arrives: connection status, or install and
 * repair when the CLI is unreachable. First-run onboarding is never shown again for this.
 */
export function Startup({ backend }: { backend: BackendState }) {
  return (
    <div className="onboarding">
      <img src="./brand/logo.svg" alt="Darkbloom" className="onboarding-logo" />
      <div className="onboarding-layout">
        <OnboardingIntro grid="idle" />
        <section className="onboarding-form">
          {unreachable.includes(backend.status.state) ? (
            <RuntimeSetup backend={backend} returningUser />
          ) : (
            <p role="status">{backend.status.message || 'Connecting to this Mac…'}</p>
          )}
        </section>
      </div>
    </div>
  );
}
