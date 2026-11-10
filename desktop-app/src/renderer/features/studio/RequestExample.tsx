import { Check, Copy } from 'lucide-react';
import { Button } from '../../components/UI';
import type { Copier } from './useCopy';

// A curl request that works as copied: the key stays a placeholder, never a revealed key.
export function RequestExample({
  baseURL,
  model,
  copier,
}: {
  baseURL?: string;
  model: string;
  copier: Copier;
}) {
  const { copied, copy } = copier;
  const curl = `curl ${baseURL || 'http://127.0.0.1:8000/v1'}/chat/completions \\\n  -H 'Authorization: Bearer <your-local-api-key>' \\\n  -H 'Content-Type: application/json' \\\n  -d '${JSON.stringify({ model, messages: [{ role: 'user', content: 'Hello' }] })}'`;
  return (
    <section className="section">
      <div className="section-title">
        <h2>Make a request</h2>
        <Button disabled={!baseURL} onClick={() => void copy(curl, 'example')}>
          {copied === 'example' ? <Check size={15} /> : <Copy size={15} />}{' '}
          {copied === 'example' ? 'Copied' : 'Copy example'}
        </Button>
      </div>
      <pre className="code-block">{curl}</pre>
    </section>
  );
}
