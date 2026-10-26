// Turns the bundled installer's output (scripts/install.sh) into plain-language
// progress and failure messages. Electron-free so it is unit tested directly.

interface Step {
  marker: RegExp;
  message: string;
  // Completes "Couldn’t install the CLI while …" when the installer fails in this step.
  phase: string;
}

// Markers the installer prints, in order. Lines are trimmed before matching. The app is a
// front end to the Darkbloom CLI, so user-facing text calls what it installs "the CLI".
const steps: Step[] = [
  {
    marker: /^→ \[1\/5\]/,
    message: 'Finding the latest CLI release…',
    phase: 'finding the latest release',
  },
  { marker: /^→ \[2\/5\]/, message: 'Downloading the CLI…', phase: 'downloading it' },
  {
    marker: /^(Bundle hash verified|Staging and verifying)/,
    message: 'Verifying the CLI’s signature…',
    phase: 'verifying its signature',
  },
  {
    marker: /^→ \[3\/5\]/,
    message: 'Setting up this Mac’s identity…',
    phase: 'setting up this Mac’s identity',
  },
  {
    marker: /^→ \[4\/5\]/,
    message: 'Setting up device verification…',
    phase: 'setting up device verification',
  },
  { marker: /^→ \[5\/5\]/, message: 'Finishing up…', phase: 'finishing up' },
  // `darkbloom update` (repair of an existing install).
  {
    marker: /^Checking for updates/,
    message: 'Checking for a CLI update…',
    phase: 'checking for an update',
  },
];
const download = steps[1];
const reasonLength = 200;

// Installer failures are `✗ …` lines (`fail_install`) or `Error: …` (platform checks).
const failureLine = /^(?:✗|Error:)\s*/;

/** One installer line as safe, short UI text: no URL queries, credentials or long tokens. */
export function sanitizeInstallLine(line: string) {
  const text = line
    .replace(failureLine, '')
    .replace(/(https?:\/\/[^\s?#]+)[?#]\S*/g, '$1')
    .replace(/\b(token|key|secret|password|authorization)\s*[:=]\s*(?:bearer\s+)?\S+/gi, '$1 …')
    .replace(/\bbearer\s+\S+/gi, 'Bearer …')
    .replace(/[A-Za-z0-9+/=_-]{32,}/g, '…')
    .replace(/\s+/g, ' ')
    .trim();
  return text.length > reasonLength ? `${text.slice(0, reasonLength - 1)}…` : text;
}

/** Follows one installer run: the current step, and the last reason it gave for failing. */
export class InstallTranscript {
  private step?: Step;
  private reason?: string;
  private percent?: number;

  /** Returns the progress message to show after this line, if it changed. */
  observe(raw: string): string | undefined {
    const line = raw.trim();
    if (!line) return;
    if (failureLine.test(line)) {
      const reason = sanitizeInstallLine(line);
      if (reason) this.reason = reason;
      return;
    }
    const step = steps.find(({ marker }) => marker.test(line));
    if (step) {
      if (step === this.step) return;
      this.step = step;
      this.percent = undefined;
      return step.message;
    }
    // curl's progress bar while downloading: "######    42.0%".
    const progress = this.step === download ? /(\d{1,3}(?:\.\d+)?)%$/.exec(line) : null;
    if (progress) {
      const percent = Math.min(100, Math.floor(Number(progress[1])));
      if (percent === this.percent) return;
      this.percent = percent;
      return `${download.message} ${percent}%`;
    }
  }

  /** The status message for a failed run; `verb` is what was being done to the CLI. */
  failure(timedOut = false, verb: 'install' | 'update' = 'install'): string {
    const during = this.step ? ` while ${this.step.phase}` : '';
    if (timedOut)
      return `${verb === 'install' ? 'Installing' : 'Updating'} the CLI timed out${during}. Check your connection and retry.`;
    const lead = `Couldn’t ${verb} the CLI${during}`;
    if (this.reason) return `${lead}: ${this.reason.replace(/[.\s]*$/, '')}.`;
    return `${lead}. Check your connection and retry.`;
  }
}

/** Splits a stream into lines (on \n or curl's \r) without buffering more than `limit` chars. */
export function lineReader(onLine: (line: string) => void, limit = 8192) {
  let partial = '';
  return {
    push(chunk: string) {
      const parts = (partial + chunk).split(/\r\n|\r|\n/);
      partial = parts.pop() ?? '';
      // Keep only the start of an overlong line.
      if (partial.length > limit) partial = partial.slice(0, limit);
      for (const line of parts) onLine(line.length > limit ? line.slice(0, limit) : line);
    },
    end() {
      if (partial) onLine(partial);
      partial = '';
    },
  };
}
