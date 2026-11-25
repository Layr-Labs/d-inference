import { ArrowRight } from 'lucide-react';
import { Button } from '../UI';

export function Welcome({ start }: { start: () => void }) {
  return (
    <>
      <h2>Put this Mac to work.</h2>
      <p>
        Darkbloom serves AI models from your Mac when it has capacity to spare. First, it checks
        that this Mac can serve them. That takes a few seconds.
      </p>
      <Button variant="primary" onClick={start}>
        Start <ArrowRight size={16} />
      </Button>
    </>
  );
}
