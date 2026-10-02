import { useEffect, useState } from 'react';
import {
  Activity,
  ArrowUpRight,
  Box,
  ChevronRight,
  CircleHelp,
  Fan,
  Home as HomeIcon,
  Layers3,
  Monitor,
  Settings2,
  Terminal,
  Trophy,
  Zap,
} from 'lucide-react';
import type { Route } from '../shared/contracts';
import { api, isPreview, useBackend } from './useBackend';
import { Home } from './features/Home';
import { Models } from './features/Models';
import { Machines } from './features/Machines';
import { Analysis, Cooling, Leaderboard, Settings, Studio, Updates } from './features/System';
import { Notice, OperationFeed } from './components/UI';
import { Onboarding } from './components/Onboarding';
const navigation = [
  { id: 'home', label: 'Home', icon: HomeIcon },
  { id: 'machines', label: 'My Macs', icon: Monitor },
  { id: 'models', label: 'Models', icon: Layers3 },
  { id: 'studio', label: 'Studio', icon: Terminal },
  { id: 'analysis', label: 'Analysis', icon: Activity },
  { id: 'cooling', label: 'Cooling', icon: Fan },
] as const;
export default function App() {
  const [route, setRoute] = useState<Route>('home');
  const backend = useBackend(route);
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
    { id: 'leaderboard', label: 'Leaderboard' },
    { id: 'updates', label: 'Updates' },
    { id: 'settings', label: 'Settings' },
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
        <div className="workspace-label">Your workspace</div>
        <nav aria-label="Main navigation">
          {navigation.map(({ id, label, icon: Icon }) => (
            <button
              key={id}
              aria-current={route === id ? 'page' : undefined}
              className={route === id ? 'active' : ''}
              onClick={() => setRoute(id)}
            >
              <Icon size={18} strokeWidth={1.55} />
              <span>{label}</span>
              {id === 'machines' && <small>{1 + (backend.cloud?.machines.length || 0)}</small>}
            </button>
          ))}
        </nav>
        <div className="sidebar-bottom">
          <div className="workspace-label">The network</div>
          <nav>
            {[
              { id: 'leaderboard' as const, label: 'Leaderboard', icon: Trophy },
              { id: 'updates' as const, label: 'Updates', icon: Box },
              { id: 'settings' as const, label: 'Settings', icon: Settings2 },
            ].map(({ id, label, icon: Icon }) => (
              <button
                className={route === id ? 'active' : ''}
                aria-current={route === id ? 'page' : undefined}
                onClick={() => setRoute(id)}
                key={id}
              >
                <Icon size={18} strokeWidth={1.55} />
                {label}
              </button>
            ))}
            <button onClick={() => void api?.openExternal('docs')}>
              <CircleHelp size={18} strokeWidth={1.55} /> Help & resources{' '}
              <ArrowUpRight size={13} />
            </button>
          </nav>
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
            <i className={backend.status.state === 'ready' ? 'online-dot' : ''} />
            {backend.status.state === 'ready' ? 'Runtime connected' : 'Reconnecting'}
          </span>
        </header>
        <main key={route} className="page-content">
          {backend.error && <Notice onClose={() => backend.setError('')}>{backend.error}</Notice>}
          {backend.status.state !== 'ready' && (
            <Notice>{backend.status.message || 'Connecting to the native runtime…'}</Notice>
          )}
          {route === 'home' && <Home backend={backend} navigate={setRoute} />}
          {route === 'machines' && <Machines backend={backend} navigate={setRoute} />}
          {route === 'models' && <Models backend={backend} />}
          {route === 'studio' && <Studio backend={backend} />}
          {route === 'analysis' && <Analysis backend={backend} />}
          {route === 'cooling' && <Cooling backend={backend} />}
          {route === 'settings' && <Settings backend={backend} />}
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
