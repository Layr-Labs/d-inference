import type { NativeModel } from '../../../shared/contracts';
import { registrationLine } from '../../models/facts';

export function ModelRegistration({ model, expected }: { model: NativeModel; expected: boolean }) {
  const line = registrationLine(model, expected);
  if (!line) return null;
  return <small className={line.warning ? 'warning-text' : 'muted'}>{line.text}</small>;
}
