import { useCallback, useEffect, useLayoutEffect, useState } from 'react';
import { Box, Home as HomeIcon, Monitor, Trophy, Zap } from 'lucide-react';
import type { Route } from '../shared/contracts';
import { api, isPreview, useBackend } from './useBackend';
import { Home } from './features/Home';
import { Machines } from './features/Machines';
import { Leaderboard } from './features/Leaderboard';
import { Updates } from './features/Updates';
import { isMachineRoute, type MachineSelection } from './features/machines/navigation';
import { Notice, OperationFeed } from './components/UI';
import { Onboarding } from './components/Onboarding';
import { Startup } from './components/Startup';
import { onboardingScenario } from './previewEligibility';
import { Earnings } from './features/Earnings';
import { Appearance } from './components/Appearance';
import { GetHelp, HelpControl } from './components/Help';
import { AccountControl } from './components/AccountControl';
import { SocialLinks } from './components/SocialLinks';
import { useFocusRecovery } from './useFocusRecovery';
const navigation = [
  { id: 'home', label: 'Home', icon: HomeIcon },
  { id: 'machines', label: 'My Macs', icon: Monitor },
  { id: 'leaderboard', label: 'Leaderboard', icon: Trophy },
  { id: 'updates', label: 'Updates', icon: Box },
] as const;
export default function App() {
  const [{ route, machine }, setView] = useState<{ route: Route; machine: MachineSelection }>({
    route: 'home',
    machine: null,
  });
  const navigate = useCallback((route: Route) => setView({ route, machine: null }), []);
  const backend = useBackend(route, machine);
  const openMachine = (id: string) =>
    setView({ route: 'machines', machine: id === backend.state?.machine.id ? null : id });
  const machineRoute = isMachineRoute(route);
  const activeRoute = machineRoute ? 'machines' : route;
  const [onboarding, setOnboarding] = useState(
    () =>
      !!onboardingScenario ||
      (!isPreview && localStorage.getItem('darkbloom.onboardingComplete') !== '1'),
  );
  const finishOnboarding = () => {
    localStorage.setItem('darkbloom.onboardingComplete', '1');
    setOnboarding(false);
  };
  useEffect(() => api?.onNavigate(navigate), [navigate]);
  // The document is the scroll container, so a new page or Mac would otherwise open at the
  // previous page's scroll offset, below its header and tabs.
  useLayoutEffect(() => {
    document.documentElement.scrollTop = 0;
  }, [route, machine]);
  useFocusRecovery(`${route}:${machine ?? ''}`, () =>
    document.querySelector<HTMLElement>('main h1'),
  );
  // Initial data and account updates can change the rendered page without navigation. Keep
  // its title current after every render without re-running navigation's focus recovery.
  useEffect(() => {
    const heading = document.querySelector('main h1')?.textContent?.trim();
    const title = heading ? `${heading} · Darkbloom` : 'Darkbloom';
    if (document.title !== title) document.title = title;
  });
  if (!backend.state || onboarding)
    return (
      <>
        <div className="drag-region" />
        {onboarding ? (
          <Onboarding backend={backend} done={finishOnboarding} />
        ) : (
          <Startup backend={backend} />
        )}
        <OperationFeed backend={backend} />
      </>
    );
  return (
    <div className="app-shell">
      <aside className="sidebar">
        <div className="brand">
          <img src="./brand/logo.svg" alt="Darkbloom" />
        </div>
        <nav aria-label="Main navigation">
          {navigation.map(({ id, label, icon: Icon }) => (
            <button
              key={id}
              aria-label={label}
              aria-current={activeRoute === id ? 'page' : undefined}
              className={activeRoute === id ? 'active' : ''}
              onClick={() => navigate(id)}
            >
              <Icon size={18} strokeWidth={1.55} />
              <span>{label}</span>
              {id === 'machines' && <small>{1 + (backend.cloud?.machines.length || 0)}</small>}
            </button>
          ))}
        </nav>
        <div className="sidebar-bottom">
          <HelpControl version={backend.state.version} />
          <SocialLinks />
          <AccountControl backend={backend} />
        </div>
      </aside>
      <div className="workspace">
        <header className="topbar">
          <span>
            {isPreview && <b className="preview-label">Development preview</b>}
            <Appearance />
            <i className={backend.status.state === 'ready' ? 'online-dot' : ''} />
            {backend.status.state === 'ready' ? 'Connected to this Mac' : 'Reconnecting'}
          </span>
        </header>
        <main
          key={machineRoute ? 'machines' : route}
          className={`page-content ${machineRoute ? 'machine-page' : route === 'home' ? 'home-page' : ''}`}
        >
          {backend.status.state !== 'ready' && (
            <Notice>
              {backend.status.message || 'Connecting to this Mac…'}
              {/* Waiting needs no next step; a runtime that can't be reached does. */}
              {backend.status.state !== 'connecting' && backend.status.state !== 'installing' && (
                <GetHelp />
              )}
            </Notice>
          )}
          {route === 'home' && (
            <Home backend={backend} navigate={navigate} openMachine={openMachine} />
          )}
          {machineRoute && (
            <Machines
              backend={backend}
              navigate={navigate}
              onSelect={openMachine}
              route={route}
              machine={machine}
            />
          )}
          {route === 'earnings' && <Earnings backend={backend} />}
          {route === 'updates' && <Updates backend={backend} />}
          {route === 'leaderboard' && <Leaderboard backend={backend} />}
          <footer className="page-footer">
            <span>
              <Zap size={12} /> Darkbloom {backend.state.version}
            </span>
            <span>Compute, powered by people.</span>
          </footer>
        </main>
        <OperationFeed backend={backend} />
      </div>
    </div>
  );
}
