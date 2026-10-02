import { useEffect, useState } from 'react';
import { Box, ChevronRight, Home as HomeIcon, Monitor, Trophy, Zap } from 'lucide-react';
import type { Route } from '../shared/contracts';
import { api, isPreview, useBackend } from './useBackend';
import { Home } from './features/Home';
import { Machines } from './features/Machines';
import { Leaderboard, Updates } from './features/System';
import { isMachineRoute } from './features/machines/navigation';
import { Notice, OperationFeed } from './components/UI';
import { Onboarding } from './components/Onboarding';
import { Earnings } from './features/Earnings';
import { Appearance } from './components/Appearance';
import { SocialLinks } from './components/SocialLinks';
const navigation = [
  { id: 'home', label: 'Home', icon: HomeIcon },
  { id: 'machines', label: 'My Macs', icon: Monitor },
  { id: 'leaderboard', label: 'Leaderboard', icon: Trophy },
  { id: 'updates', label: 'Updates', icon: Box },
] as const;
export default function App() {
  const [route, setRoute] = useState<Route>('home');
  const backend = useBackend(route);
  const machineRoute = isMachineRoute(route);
  const activeRoute = machineRoute ? 'machines' : route;
  const [onboarding, setOnboarding] = useState(
    () => !isPreview && localStorage.getItem('darkbloom.onboardingComplete') !== '1',
  );
  const finishOnboarding = () => {
    localStorage.setItem('darkbloom.onboardingComplete', '1');
    setOnboarding(false);
  };
  useEffect(() => api?.onNavigate(setRoute), []);
  const title = [
    ...navigation,
    { id: 'settings', label: 'Settings' },
    { id: 'models', label: 'Models' },
    { id: 'studio', label: 'Studio' },
    { id: 'analysis', label: 'Analysis' },
    { id: 'earnings', label: 'Earnings' },
    { id: 'cooling', label: 'Cooling' },
  ].find((item) => item.id === route)?.label;
  if (!backend.state || onboarding)
    return (
      <>
        <div className="drag-region" />
        <Onboarding backend={backend} done={finishOnboarding} />
        {backend.error && (
          <div className="onboarding-error">
            <Notice onClose={() => backend.setError('')}>{backend.error}</Notice>
          </div>
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
              onClick={() => setRoute(id)}
            >
              <Icon size={18} strokeWidth={1.55} />
              <span>{label}</span>
              {id === 'machines' && <small>{1 + (backend.cloud?.machines.length || 0)}</small>}
            </button>
          ))}
        </nav>
        <div className="sidebar-bottom">
          <SocialLinks />
          <button className="local-profile" onClick={() => setOnboarding(true)}>
            <div className="profile-icon">
              <Monitor size={17} />
            </div>
            <span>
              <strong>{backend.state.machine.name}</strong>
              <small>
                {backend.state.state === 'running' ? 'Providing to the grid' : 'Ready when you are'}
              </small>
            </span>
            <i className={backend.state.state === 'running' ? 'online-dot' : ''} />
          </button>
        </div>
      </aside>
      <div className="workspace">
        <header className="topbar">
          <span>
            Workspace <ChevronRight size={12} /> <strong>{title}</strong>
          </span>
          <span>
            {isPreview && <b className="preview-label">Development preview</b>}
            <Appearance />
            <i className={backend.status.state === 'ready' ? 'online-dot' : ''} />
            {backend.status.state === 'ready' ? 'Runtime connected' : 'Reconnecting'}
          </span>
        </header>
        <main
          key={machineRoute ? 'machines' : route}
          className={`page-content ${machineRoute ? 'machine-page' : ''}`}
        >
          {backend.error && <Notice onClose={() => backend.setError('')}>{backend.error}</Notice>}
          {backend.status.state !== 'ready' && (
            <Notice>{backend.status.message || 'Connecting to the native runtime…'}</Notice>
          )}
          {route === 'home' && <Home backend={backend} navigate={setRoute} />}
          {machineRoute && <Machines backend={backend} navigate={setRoute} route={route} />}
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
        {!machineRoute && <OperationFeed backend={backend} />}
      </div>
    </div>
  );
}
