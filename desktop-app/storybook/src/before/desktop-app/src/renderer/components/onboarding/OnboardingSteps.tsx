import { Check } from 'lucide-react';

const steps = ['Check this Mac', 'Start'];

export function OnboardingSteps({ current }: { current: number }) {
  return (
    <ol className="steps" aria-label="Setup steps">
      {steps.map((label, index) => (
        <li
          className={index === current ? 'current' : index < current ? 'complete' : ''}
          aria-current={index === current ? 'step' : undefined}
          key={label}
        >
          <span>{index < current ? <Check size={12} /> : index + 1}</span>
          {label}
        </li>
      ))}
    </ol>
  );
}
