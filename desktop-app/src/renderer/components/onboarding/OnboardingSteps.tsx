import { Check } from 'lucide-react';

// The first step's page is headed Install the Darkbloom CLI; its label stays short to fit.
const steps = ['Install CLI', 'Check this Mac', 'Link your account', 'Start'];
const linkStep = 2;

// Linking is done only once the account is linked; a linked Mac passes it without linking.
export function OnboardingSteps({ current, linked }: { current: number; linked: boolean }) {
  return (
    <ol className="steps" aria-label="Setup steps">
      {steps.map((label, index) => {
        const complete = index < current && (index !== linkStep || linked);
        return (
          <li
            className={index === current ? 'current' : complete ? 'complete' : ''}
            aria-current={index === current ? 'step' : undefined}
            key={label}
          >
            <span>{complete ? <Check size={12} /> : index + 1}</span>
            {label}
          </li>
        );
      })}
    </ol>
  );
}
