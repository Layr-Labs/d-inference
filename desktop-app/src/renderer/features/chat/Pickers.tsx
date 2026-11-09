import { useEffect, useId, useRef, useState, type KeyboardEvent, type ReactNode } from 'react';
import { Brain, Check, ChevronDown } from 'lucide-react';
import { reasoningEfforts, type ChatModel, type ReasoningEffort } from '../../../shared/chat';
import { PixelLoader } from './Indicators';
import { contextLabel, modelName, modelPlace, placeLabels, type ModelPlace } from './text';
import styles from './chat.module.css';

export interface PickerOption {
  value: string;
  label: string;
  detail?: string;
  group?: string;
}

// A button that opens a listbox under it: arrows move, Enter or Space chooses, Escape closes and
// returns to the button, and a click elsewhere closes it.
export function Picker({
  label,
  value,
  options,
  onChange,
  title,
  children,
}: {
  // The listbox's name, such as "Model".
  label: string;
  value: string;
  options: PickerOption[];
  onChange: (value: string) => void;
  // The button's accessible name, such as "Model: Qwen 3.8 27B".
  title: string;
  children: ReactNode;
}) {
  const [open, setOpen] = useState(false);
  const [active, setActive] = useState(0);
  const wrapper = useRef<HTMLDivElement>(null);
  const button = useRef<HTMLButtonElement>(null);
  const list = useRef<HTMLDivElement>(null);
  const base = `picker${useId().replace(/[^\w-]/g, '')}`;
  const selected = Math.max(
    0,
    options.findIndex((option) => option.value === value),
  );
  const show = () => {
    setActive(selected);
    setOpen(true);
  };
  const close = (refocus = true) => {
    setOpen(false);
    if (refocus) button.current?.focus();
  };
  const choose = (index: number) => {
    const option = options[index];
    if (option) onChange(option.value);
    close();
  };
  useEffect(() => {
    if (!open) return;
    list.current?.focus();
    const away = (event: PointerEvent) => {
      if (!wrapper.current?.contains(event.target as Node)) setOpen(false);
    };
    document.addEventListener('pointerdown', away);
    return () => document.removeEventListener('pointerdown', away);
  }, [open]);
  useEffect(() => {
    if (open) document.getElementById(`${base}-${active}`)?.scrollIntoView?.({ block: 'nearest' });
  }, [open, active, base]);
  const keys = (event: KeyboardEvent) => {
    const moves: Record<string, number> = {
      ArrowDown: Math.min(options.length - 1, active + 1),
      ArrowUp: Math.max(0, active - 1),
      Home: 0,
      End: options.length - 1,
    };
    if (event.key in moves) {
      event.preventDefault();
      setActive(moves[event.key]);
    } else if (event.key === 'Enter' || event.key === ' ') {
      event.preventDefault();
      choose(active);
    } else if (event.key === 'Escape') {
      event.preventDefault();
      event.stopPropagation();
      close();
    } else if (event.key === 'Tab') close(false);
  };
  const groups: { title?: string; items: { option: PickerOption; index: number }[] }[] = [];
  options.forEach((option, index) => {
    const last = groups.at(-1);
    if (last && last.title === option.group) last.items.push({ option, index });
    else groups.push({ title: option.group, items: [{ option, index }] });
  });
  return (
    <div ref={wrapper} className={styles.picker}>
      <button
        ref={button}
        type="button"
        className={styles.pickerButton}
        aria-haspopup="listbox"
        aria-expanded={open}
        aria-controls={open ? `${base}-list` : undefined}
        aria-label={title}
        onClick={() => (open ? close() : show())}
        onKeyDown={(event) => {
          if (event.key === 'ArrowDown' || event.key === 'ArrowUp') {
            event.preventDefault();
            show();
          }
        }}
      >
        {children}
        <ChevronDown size={12} strokeWidth={1.8} aria-hidden="true" />
      </button>
      {open && (
        <div
          ref={list}
          id={`${base}-list`}
          role="listbox"
          aria-label={label}
          aria-activedescendant={`${base}-${active}`}
          tabIndex={-1}
          className={styles.popover}
          onKeyDown={keys}
        >
          {groups.map((group, groupIndex) => (
            <div
              key={group.title ?? groupIndex}
              role="group"
              aria-labelledby={group.title ? `${base}-group-${groupIndex}` : undefined}
            >
              {group.title && (
                <div id={`${base}-group-${groupIndex}`} className={styles.groupLabel}>
                  {group.title}
                </div>
              )}
              {group.items.map(({ option, index }) => (
                <div
                  key={option.value}
                  id={`${base}-${index}`}
                  role="option"
                  aria-selected={option.value === value}
                  data-active={index === active || undefined}
                  className={styles.option}
                  onPointerMove={() => index !== active && setActive(index)}
                  onClick={() => choose(index)}
                >
                  <span className={styles.optionText}>
                    <span>{option.label}</span>
                    {option.detail && <small>{option.detail}</small>}
                  </span>
                  <Check size={14} strokeWidth={1.8} aria-hidden="true" />
                </div>
              ))}
            </div>
          ))}
        </div>
      )}
    </div>
  );
}

const placeOrder: ModelPlace[] = ['this-mac', 'my-macs', 'darkbloom'];
const groupTitles: Record<ModelPlace, string> = {
  ...placeLabels,
  darkbloom: 'Darkbloom network · billed',
};

// Which model answers: this Mac's first, then your other Macs', then the network's, as the local
// API lists them.
export function ModelPicker({
  models,
  value,
  onChange,
}: {
  models: ChatModel[];
  value?: ChatModel;
  onChange: (id: string) => void;
}) {
  const options = placeOrder.flatMap((place) =>
    models
      .filter((model) => modelPlace(model) === place)
      .map((model) => ({
        value: model.id,
        label: modelName(model),
        group: groupTitles[place],
        detail:
          [
            modelName(model) !== model.id ? model.id : undefined,
            model.reasoning ? 'Reasons' : undefined,
            contextLabel(model.context_length),
          ]
            .filter(Boolean)
            .join(' · ') || undefined,
      })),
  );
  const name = value ? modelName(value) : 'Choose a model';
  return (
    <Picker
      label="Model"
      title={`Model: ${name}`}
      value={value?.id ?? ''}
      options={options}
      onChange={onChange}
    >
      <span>{name}</span>
    </Picker>
  );
}

export const effortLabels: Record<ReasoningEffort, string> = {
  none: 'None',
  minimal: 'Minimal',
  low: 'Low',
  medium: 'Medium',
  high: 'High',
  xhigh: 'Extra high',
  max: 'Max',
};

// How hard a model that reasons thinks: its own default, or one of the seven efforts it takes.
export function EffortPicker({
  value,
  efforts,
  onChange,
}: {
  value: ReasoningEffort | null;
  efforts?: ReasoningEffort[] | null;
  onChange: (effort: ReasoningEffort | null) => void;
}) {
  const choices = efforts?.length ? efforts : [...reasoningEfforts];
  const current = value && choices.includes(value) ? value : null;
  const label = current ? effortLabels[current] : 'Default';
  return (
    <Picker
      label="Reasoning effort"
      title={`Reasoning effort: ${label}`}
      value={current ?? ''}
      options={[
        { value: '', label: 'Default', detail: 'The model’s own' },
        ...choices.map((effort) => ({ value: effort, label: effortLabels[effort] })),
      ]}
      onChange={(next) => onChange((next || null) as ReasoningEffort | null)}
    >
      <Brain size={14} strokeWidth={1.55} aria-hidden="true" />
      <span>{label}</span>
    </Picker>
  );
}

// While the list loads.
export function ModelsLoading() {
  return (
    <span className={styles.loadingModels} role="status" aria-label="Loading models">
      <PixelLoader size={10} />
    </span>
  );
}
