import type { ReactNode } from 'react';
import {
  BatteryCharging,
  Boxes,
  Check,
  Circle,
  Moon,
  Wifi,
  X,
  type LucideIcon,
} from 'lucide-react';
import { macosMajor, minimumMacOS } from '../../../shared/macos';
import type { BackendState } from '../../useBackend';
import { Button } from '../../components/UI';
import { openSoftwareUpdate } from '../../softwareUpdate';
import { useWaitlist } from '../waitlists/useWaitlist';
import { WaitlistCard } from '../waitlists/WaitlistCard';
import { SetupForm } from './SetupForm';
import styles from './sandboxes.module.css';

// This Mac without the add-on: what it is, what it needs, and setup once the account may use it.
export function NotInstalled({ backend }: { backend: BackendState }) {
  const state = backend.state!;
  const macos = backend.system?.macosVersion;
  const major = macosMajor(macos);
  const tooOld = major !== undefined && major < minimumMacOS;
  return (
    <>
      <section className={styles.intro} aria-label="About Darkbloom Sandbox">
        <span className={styles.introIcon} aria-hidden>
          <Boxes size={20} strokeWidth={1.6} />
        </span>
        <div>
          <p>Runs approved GitHub Actions jobs in Linux and macOS VMs on this Mac.</p>
          <p>
            Each job pays its price minus a 10% fee into your Darkbloom balance. Inference pauses
            while a job runs.
          </p>
        </div>
      </section>
      <section className={styles.requirements} aria-label="Requirements">
        <div>
          <h3>Needs</h3>
          <ul>
            <Requirement state={/^Apple M/i.test(state.machine.chip) ? 'met' : 'unknown'}>
              Apple silicon
            </Requirement>
            <Requirement state={major === undefined ? 'unknown' : tooOld ? 'unmet' : 'met'}>
              macOS {minimumMacOS} or later
              {macos && <small>macOS {macos}</small>}
            </Requirement>
            <Requirement state="unknown">Logged in at this Mac’s desktop</Requirement>
            <Requirement state="unknown">A network connection</Requirement>
          </ul>
        </div>
        <div>
          <h3>Avoid · lost jobs aren’t paid</h3>
          <ul>
            <Warning icon={Wifi}>
              Wi-Fi
              <small>Ethernet is faster and steadier</small>
            </Warning>
            <Warning icon={BatteryCharging}>
              Battery
              <small>Keep this Mac plugged in</small>
            </Warning>
            <Warning icon={Moon}>
              Sleep on the power adapter
              <small>
                <code>sudo pmset -c sleep 0</code>
              </small>
            </Warning>
          </ul>
        </div>
      </section>
      {tooOld ? (
        <div className={styles.blocked}>
          <p>
            Darkbloom Sandbox needs macOS {minimumMacOS} or later. This Mac runs macOS {macos}.
          </p>
          <Button onClick={openSoftwareUpdate}>Open Software Update</Button>
        </div>
      ) : (
        <SetupGate backend={backend} />
      )}
    </>
  );
}

type RequirementState = 'met' | 'unmet' | 'unknown';
const requirementWords: Record<RequirementState, string> = {
  met: 'Met',
  unmet: 'Not met',
  unknown: 'Setup checks this',
};

function Requirement({ state, children }: { state: RequirementState; children: ReactNode }) {
  return (
    <li data-state={state}>
      {state === 'met' ? (
        <Check size={14} aria-hidden />
      ) : state === 'unmet' ? (
        <X size={14} aria-hidden />
      ) : (
        <Circle size={7} aria-hidden />
      )}
      <span>
        <span className="sr-only">{requirementWords[state]}: </span>
        {children}
      </span>
    </li>
  );
}

function Warning({ icon: Icon, children }: { icon: LucideIcon; children: ReactNode }) {
  return (
    <li data-state="warn">
      <Icon size={14} aria-hidden />
      <span>{children}</span>
    </li>
  );
}

// Setup needs an account Darkbloom approved from the `sandbox` waitlist, or a coordinator
// without that waitlist. A runtime without the `waitlists` capability can't say, so the CLI's
// own check decides. Otherwise the waitlist's own notice says where the account stands and what
// to do: join, link this Mac, or try again.
function SetupGate({ backend }: { backend: BackendState }) {
  const waitlist = useWaitlist(backend, 'sandbox');
  if (waitlist.open || waitlist.standing === 'unsupported') return <SetupForm backend={backend} />;
  if (waitlist.standing === 'loading')
    return (
      <p className={`${styles.note} ${styles.gate}`} role="status">
        Checking the waitlist…
      </p>
    );
  return (
    <div className={styles.gate}>
      <WaitlistCard feature="sandbox" backend={backend} compact />
    </div>
  );
}
