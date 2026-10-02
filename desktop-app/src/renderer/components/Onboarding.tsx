import { ArrowRight, Check, Download, LoaderCircle, ShieldCheck } from 'lucide-react';
import { useState } from 'react';
import type { BackendState } from '../useBackend';
import { api } from '../useBackend';
import { Button, External, Notice } from './UI';

export function Onboarding({ backend, done }: { backend: BackendState; done: () => void }) {
  const [step, setStep] = useState(0);
  const [mode, setMode] = useState<'network' | 'local'>('network');
  const [selected, setSelected] = useState('');
  const [error, setError] = useState('');
  const connected = backend.status.state === 'ready' && !!backend.state;
  const steps = ['Connect', 'Choose a model', 'Start'];
  const model = backend.state?.models.find((model) => model.id === selected);
  async function install() {
    try {
      setError('');
      await api?.install();
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Installation failed');
    }
  }
  return (
    <div className="onboarding">
      <img src="./brand/logo.svg" alt="Darkbloom" className="onboarding-logo" />
      <div className="onboarding-layout">
        <div className="onboarding-intro">
          <span className="blue-label">Your Mac has more to give.</span>
          <h1>
            Be part
            <br />
            of the grid.
          </h1>
          <p>
            Run powerful models on your Mac.
            <br />
            Put idle compute to work on your terms.
          </p>
          <div className="onboarding-grid" aria-hidden="true">
            {Array.from({ length: 42 }, (_, i) => (
              <i className={i % 5 === 0 || i % 7 === 0 ? 'lit' : ''} key={i} />
            ))}
          </div>
        </div>
        <section className="onboarding-form">
          <ol className="steps">
            {steps.map((item, i) => (
              <li className={i === step ? 'current' : i < step ? 'complete' : ''} key={item}>
                <span>{i < step ? <Check size={12} /> : i + 1}</span>
                {item}
              </li>
            ))}
          </ol>
          {step === 0 && (
            <>
              <h2>{connected ? 'This Mac is ready.' : 'Connect your Mac.'}</h2>
              <p>
                Darkbloom installs the native runtime and keeps it up to date. Your provider works
                independently of this window.
              </p>
              {error && <Notice>{error}</Notice>}
              {backend.status.message && <p className="muted">{backend.status.message}</p>}
              {connected ? (
                <>
                  <div className="setup-machine">
                    <ShieldCheck size={25} />
                    <div>
                      <strong>{backend.state!.machine.name}</strong>
                      <span>
                        {backend.state!.machine.chip} · {backend.state!.machine.memory_gb} GB
                      </span>
                    </div>
                    <Check size={17} />
                  </div>
                  <label className="choice">
                    <input
                      type="radio"
                      checked={mode === 'network'}
                      onChange={() => setMode('network')}
                    />
                    <span>
                      <strong>Contribute to Darkbloom</strong>
                      <small>Make this Mac available and earn from its work.</small>
                    </span>
                  </label>
                  <label className="choice">
                    <input
                      type="radio"
                      checked={mode === 'local'}
                      onChange={() => setMode('local')}
                    />
                    <span>
                      <strong>Use models locally</strong>
                      <small>Run your own apps with a local inference endpoint.</small>
                    </span>
                  </label>
                  {mode === 'network' && !backend.state!.linked && (
                    <Button onClick={() => void backend.act({ action: 'link' })}>
                      Link account
                    </Button>
                  )}
                  {backend.state!.link && (
                    <div className="setup-code">
                      <strong>{backend.state!.link.code}</strong>
                      <Button onClick={() => void api?.openExternal('link')}>Open browser</Button>
                    </div>
                  )}
                  <Button
                    variant="primary"
                    disabled={mode === 'network' && !backend.state!.linked}
                    onClick={() => setStep(1)}
                  >
                    Continue <ArrowRight size={16} />
                  </Button>
                  <Button variant="quiet" onClick={done}>
                    Open dashboard
                  </Button>
                </>
              ) : (
                <Button
                  variant="primary"
                  disabled={!api || backend.status.state === 'installing'}
                  onClick={() => void install()}
                >
                  {backend.status.state === 'installing' ? (
                    <LoaderCircle className="spin" size={16} />
                  ) : (
                    <Download size={16} />
                  )}{' '}
                  Install runtime
                </Button>
              )}
            </>
          )}
          {step === 1 && (
            <>
              <h2>Choose your first model.</h2>
              <p>The native runtime checks each model before loading it.</p>
              <div className="setup-models">
                {backend.state?.models.map((model) => (
                  <label
                    className={`choice ${selected === model.id ? 'selected' : ''}`}
                    key={model.id}
                  >
                    <input
                      type="radio"
                      name="first-model"
                      checked={selected === model.id}
                      onChange={() => setSelected(model.id)}
                    />
                    <span>
                      <strong>{model.display_name}</strong>
                      <small>
                        {model.size_gb.toFixed(1)} GB download ·{' '}
                        {model.downloaded ? 'Ready on disk' : 'Not downloaded'}
                      </small>
                    </span>
                  </label>
                ))}
              </div>
              {model && !model.downloaded && (
                <Button
                  disabled={backend.busy}
                  onClick={() => void backend.act({ action: 'download', model: model.id })}
                >
                  <Download size={15} /> Download model
                </Button>
              )}
              <div className="dialog-actions">
                <Button onClick={() => setStep(0)}>Back</Button>
                <Button
                  variant="primary"
                  disabled={!model?.downloaded || !model.eligible}
                  onClick={() => setStep(2)}
                >
                  Continue <ArrowRight size={16} />
                </Button>
              </div>
            </>
          )}
          {step === 2 && (
            <>
              <h2>Ready when you are.</h2>
              <p>
                {model?.display_name} will run on this Mac. Stop it any time from the app or the
                menu bar.
              </p>
              <div className="setup-machine">
                <ShieldCheck size={25} />
                <span>
                  Automatic verified updates
                  <br />
                  <small className="muted">Managed by the native runtime.</small>
                </span>
              </div>
              <Button
                variant="primary"
                disabled={backend.busy || !selected}
                onClick={async () => {
                  if (
                    backend.state &&
                    !(await backend.act(
                      { action: 'settings', ...backend.state.settings, auto_update: true },
                      true,
                    ))
                  )
                    return;
                  if (
                    await backend.act(
                      {
                        action: 'start',
                        models: [selected],
                        local: mode === 'local',
                        endpoint: true,
                      },
                      true,
                    )
                  )
                    done();
                }}
              >
                Start {mode === 'local' ? 'local inference' : 'providing'} <ArrowRight size={16} />
              </Button>
              <p className="terms-note">
                By turning on, you agree to our <External target="terms">Terms of Service</External>
              </p>
              <Button variant="quiet" onClick={done}>
                Explore the app first
              </Button>
            </>
          )}
        </section>
      </div>
      <footer>
        <span>Powered by your Mac. Built by people.</span>
        <External target="docs">Read the guide</External>
      </footer>
    </div>
  );
}
