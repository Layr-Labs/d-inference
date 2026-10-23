import { Download } from 'lucide-react';
import { useState } from 'react';
import type { BackendState } from '../../useBackend';
import { api } from '../../useBackend';
import { Button, Notice } from '../UI';

export function RuntimeSetup({ backend }: { backend: BackendState }) {
  const [error, setError] = useState('');
  const missing = backend.status.state === 'missing';
  async function install() {
    try {
      setError('');
      await api?.install();
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Installation failed');
    }
  }
  return (
    <>
      <h2>{missing ? 'Install Darkbloom to check this Mac.' : 'We couldn’t check this Mac.'}</h2>
      <p>
        {missing
          ? 'Darkbloom installs its verified native runtime, then checks whether this Mac can serve models. Your provider works independently of this window.'
          : 'Darkbloom couldn’t reach its native runtime. Repair it and the check runs again.'}
      </p>
      {error && <Notice>{error}</Notice>}
      {backend.status.message && <p className="muted">{backend.status.message}</p>}
      <Button variant="primary" disabled={!api} onClick={() => void install()}>
        <Download size={16} /> {missing ? 'Install runtime' : 'Repair runtime'}
      </Button>
    </>
  );
}
