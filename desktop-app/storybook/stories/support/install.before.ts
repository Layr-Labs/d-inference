// Runs before the real useBackend module, which reads window.darkbloom once when it loads.
import { bridges } from './bridge';
(window as unknown as { darkbloom: unknown }).darkbloom = bridges.before.api;
