import type { DesktopAPI } from '../../../shared/contracts';
import { errorMessage, submitAction, unsupported } from '../../actions';

const emailPattern = /^[^\s@]+@[^\s@.]+(\.[^\s@.]+)+$/;
export const validEmail = (email: string) => email.length <= 254 && emailPattern.test(email);

export async function joinWaitlist(api: DesktopAPI | undefined, email: string, reasons: string[]) {
  if (!api) throw new Error('Open the Darkbloom app to join the waitlist.');
  await submitAction(
    api,
    { action: 'waitlist', email, reasons },
    { timeoutMs: 60_000, timeout: 'The waitlist didn’t answer. Try again in a moment.' },
  ).catch((error: unknown) => {
    throw errorMessage(error) ? error : new Error('The waitlist didn’t confirm your sign-up.');
  });
}

export function waitlistError(error: unknown) {
  if (unsupported(error)) return 'This version of Darkbloom doesn’t support sign-ups yet.';
  return errorMessage(error) || 'Check your connection and try again.';
}
