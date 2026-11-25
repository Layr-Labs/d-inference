import { Plus, X } from 'lucide-react';
import type { Schedule } from '../../shared/contracts';
import { Button } from './UI';
const days = ['mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun'];
export function ScheduleEditor({
  value,
  onChange,
}: {
  value: Schedule;
  onChange: (value: Schedule) => void;
}) {
  return (
    <section className="settings-section">
      <h2>Availability</h2>
      <label className="setting-row">
        <span>
          <strong>Use a weekly schedule</strong>
          <small>Times use this Mac’s local timezone. Restart to apply changes.</small>
        </span>
        <input
          className="switch"
          type="checkbox"
          role="switch"
          checked={value.enabled}
          onChange={(event) =>
            onChange({
              ...value,
              enabled: event.target.checked,
              windows: value.windows.length
                ? value.windows
                : [{ days: ['mon', 'tue', 'wed', 'thu', 'fri'], start: '18:00', end: '09:00' }],
            })
          }
        />
      </label>
      {value.enabled && (
        <>
          <div className="schedule-windows">
            {value.windows.map((window, index) => (
              <div className="schedule-window" key={index}>
                <div className="schedule-days">
                  {days.map((day) => (
                    <label key={day}>
                      <input
                        type="checkbox"
                        checked={window.days.includes(day)}
                        onChange={(event) =>
                          onChange({
                            ...value,
                            windows: value.windows.map((item, i) =>
                              i === index
                                ? {
                                    ...item,
                                    days: event.target.checked
                                      ? [...item.days, day]
                                      : item.days.filter((value) => value !== day),
                                  }
                                : item,
                            ),
                          })
                        }
                      />
                      <span>{day.slice(0, 1).toUpperCase() + day.slice(1)}</span>
                    </label>
                  ))}
                </div>
                <div className="schedule-time">
                  <input
                    aria-label={`Window ${index + 1} start`}
                    type="time"
                    value={window.start}
                    onChange={(event) =>
                      onChange({
                        ...value,
                        windows: value.windows.map((item, i) =>
                          i === index ? { ...item, start: event.target.value } : item,
                        ),
                      })
                    }
                  />
                  <span>to</span>
                  <input
                    aria-label={`Window ${index + 1} end`}
                    type="time"
                    value={window.end}
                    onChange={(event) =>
                      onChange({
                        ...value,
                        windows: value.windows.map((item, i) =>
                          i === index ? { ...item, end: event.target.value } : item,
                        ),
                      })
                    }
                  />
                  <button
                    aria-label={`Remove window ${index + 1}`}
                    className="icon-button"
                    onClick={() =>
                      onChange({ ...value, windows: value.windows.filter((_, i) => i !== index) })
                    }
                  >
                    <X size={16} />
                  </button>
                </div>
              </div>
            ))}
          </div>
          <Button
            disabled={value.windows.length >= 14}
            onClick={() =>
              onChange({
                ...value,
                windows: [...value.windows, { days: ['sat', 'sun'], start: '00:00', end: '00:00' }],
              })
            }
          >
            <Plus size={14} /> Add window
          </Button>
          <p className="muted schedule-note">
            An end time before the start runs overnight. Equal times make a 24-hour window.
          </p>
        </>
      )}
    </section>
  );
}
