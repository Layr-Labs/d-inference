import { Check } from 'lucide-react';

const steps = ['Link your account', 'Check this Mac', 'Start'];

// Linking is done only once the account is linked: local only passes it without linking.
export function OnboardingSteps({ current, linked }: { current: number; linked: boolean }) {
  return (
    <ol className="steps" aria-label="Setup steps">
      {steps.map((label, index) => {
        const complete = index < current && (index > 0 || linked);
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
