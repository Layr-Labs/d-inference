import {
  useCallback,
  useEffect,
  useId,
  useMemo,
  useRef,
  useState,
  useSyncExternalStore,
  type ReactNode,
} from 'react';
import { Gauge, PanelLeft, SquarePen } from 'lucide-react';
import type { Route } from '../../../shared/contracts';
import { isReasoningEffort, type ChatModels, type ReasoningEffort } from '../../../shared/chat';
import { api, type BackendState } from '../../useBackend';
import { useReducedMotion } from '../../useReducedMotion';
import { Button } from '../../components/UI';
import { ChatList } from './ChatList';
import { Composer } from './Composer';
import { Hero } from './Hero';
import { PixelLoader } from './Indicators';
import { MessageList } from './Messages';
import { EffortPicker, ModelPicker, ModelsLoading } from './Pickers';
import { chatStore, useChatState, type ChatStore } from './store';
import { readPref, windowStorage, writePref } from './storage';
import {
  fixed,
  grouped,
  launchTagline,
  modelName,
  modelPlace,
  placeLines,
  placeTaglines,
} from './text';
import styles from './chat.module.css';

// The launch line: the first one this app launch read, kept while it runs.
let launchLine: string | undefined;
const tagline = () => (launchLine ??= launchTagline(windowStorage()));
// The last model list, shown while the page reads it again.
let lastModels: ChatModels | undefined;

const narrowQuery = '(max-width: 760px)';
const narrowNow = () =>
  typeof window !== 'undefined' && !!window.matchMedia?.(narrowQuery)?.matches;
function useNarrow() {
  return useSyncExternalStore(
    (change) => {
      const query = window.matchMedia?.(narrowQuery);
      query?.addEventListener?.('change', change);
      return () => query?.removeEventListener?.('change', change);
    },
    narrowNow,
    () => false,
  );
}

const notAnswering = 'This Mac’s local API didn’t answer.';

// Chat with the models this Mac serves on its local API, as the iPhone app chats: the mark and
// the launch line when empty, then the conversation, typography first.
export function Chat({
  backend,
  navigate,
  store = chatStore(),
}: {
  backend: BackendState;
  navigate: (route: Route) => void;
  store?: ChatStore;
}) {
  const state = useChatState(store);
  const reduced = useReducedMotion();
  const narrow = useNarrow();
  const storage = windowStorage();
  const field = useRef<HTMLTextAreaElement>(null);
  const listID = `chats${useId().replace(/[^\w-]/g, '')}`;
  const [models, setModels] = useState<ChatModels | undefined>(lastModels);
  const [loading, setLoading] = useState(true);
  const [chosen, setChosen] = useState(() => readPref(storage, 'model'));
  const [effort, setEffort] = useState<ReasoningEffort | null>(() => {
    const saved = readPref(storage, 'effort');
    return isReasoningEffort(saved) ? saved : null;
  });
  const [speed, setSpeed] = useState(() => readPref(storage, 'speed') === '1');
  // The list stays beside the chat on a wide window (remembered), and lies over it when narrow.
  const [listOpen, setListOpen] = useState(() => readPref(storage, 'list') !== '0');
  const [overlay, setOverlay] = useState(false);
  const open = narrow ? overlay : listOpen;

  const endpoint = backend.state?.endpoint;
  const endpointKey = endpoint
    ? [endpoint.base_url, endpoint.authenticated, ...endpoint.models].join(' ')
    : '';
  const request = useRef(0);
  const load = useCallback(async () => {
    const run = ++request.current;
    setLoading(true);
    let result: ChatModels;
    try {
      result = api
        ? await api.chatModels()
        : { models: [], code: 'unavailable', error: 'Open the Darkbloom app to chat.' };
    } catch {
      result = { models: [], code: 'unavailable', error: notAnswering };
    }
    if (run !== request.current) return;
    lastModels = result;
    setModels(result);
    setLoading(false);
  }, []);
  // Again whenever this Mac's local API starts, stops or changes what it serves.
  useEffect(() => {
    void load();
  }, [load, endpointKey]);

  const available = useMemo(() => models?.models ?? [], [models]);
  const conversation = state.conversations.find((item) => item.id === state.current);
  const hasMessages = !!conversation?.messages.length;
  const model =
    available.find((item) => item.id === conversation?.model) ??
    available.find((item) => item.id === chosen) ??
    available.find((item) => modelPlace(item) === 'this-mac') ??
    available[0];
  const place = model ? modelPlace(model) : 'this-mac';
  const live = Object.entries(state.live).find(([, entry]) => entry.conversation === state.current);
  const answering = useMemo(
    () => new Set(Object.values(state.live).map((entry) => entry.conversation)),
    [state.live],
  );
  const names = useCallback(
    (id: string | undefined) => {
      if (!id) return undefined;
      const listed = available.find((item) => item.id === id);
      return listed ? modelName(listed) : (id.split('/').at(-1) ?? id);
    },
    [available],
  );

  const chooseModel = (id: string) => {
    setChosen(id);
    writePref(storage, 'model', id);
    store.setModel(id);
  };
  const chooseEffort = (next: ReasoningEffort | null) => {
    setEffort(next);
    writePref(storage, 'effort', next);
  };
  const toggleSpeed = () => {
    setSpeed(!speed);
    writePref(storage, 'speed', speed ? '0' : '1');
  };
  const toggleList = () => {
    if (narrow) return setOverlay(!overlay);
    setListOpen(!listOpen);
    writePref(storage, 'list', listOpen ? '0' : '1');
  };
  const newChat = () => {
    store.select(null);
    setOverlay(false);
    requestAnimationFrame(() => field.current?.focus());
  };
  const select = (id: string) => {
    store.select(id);
    setOverlay(false);
  };
  const send = (text: string) => {
    if (model) void store.send(text, model.id, model.reasoning ? effort : null);
  };

  let bottom: ReactNode;
  if (models?.code === 'no_endpoint')
    bottom = (
      <div className={styles.unavailable}>
        <span>Chat uses this Mac’s local API.</span>
        <Button variant="primary" onClick={() => navigate('studio')}>
          Open Studio
        </Button>
      </div>
    );
  else if (models?.code)
    bottom = (
      <div className={styles.unavailable} role="alert">
        <span>{models.error || notAnswering}</span>
        <Button onClick={() => void load()} disabled={loading}>
          {loading && <PixelLoader size={10} />}
          Try again
        </Button>
      </div>
    );
  else if (models && !available.length && !loading)
    bottom = (
      <div className={styles.unavailable}>
        <span>This Mac’s local API lists no models.</span>
        <Button variant="primary" onClick={() => navigate('studio')}>
          Open Studio
        </Button>
      </div>
    );
  else {
    const entry = live?.[1];
    const seconds = entry?.first_token ? (Date.now() - entry.first_token) / 1000 : 0;
    bottom = (
      <Composer
        field={field}
        draft={state.draft}
        onDraft={(draft) => store.setDraft(draft)}
        placeholder={model ? `Ask ${modelName(model)}` : 'Message'}
        disabled={!model}
        answering={!!live}
        onSend={send}
        onStop={() => store.stop(state.current)}
        above={
          speed &&
          entry?.first_token && (
            <p className={styles.live}>
              <span>{names(conversation?.model) ?? (model && modelName(model))}</span>
              <span aria-hidden="true">·</span>
              <span>{seconds > 0.25 ? fixed(entry.pieces / seconds) : '–'} tok/s</span>
              <span aria-hidden="true">·</span>
              <span>{grouped(entry.pieces)} tokens</span>
              <span className={styles.where}>{placeLines[place]}</span>
            </p>
          )
        }
      />
    );
  }

  return (
    <div className={styles.chat} data-list={open ? 'open' : 'closed'}>
      <h1 className={styles.srOnly}>Chat</h1>
      <ChatList
        id={listID}
        conversations={state.conversations}
        current={state.current}
        answering={answering}
        onSelect={select}
        onNew={newChat}
        onDelete={(id) => store.remove(id)}
      />
      {narrow && overlay && (
        <div className={styles.scrim} aria-hidden="true" onClick={() => setOverlay(false)} />
      )}
      <section className={styles.conversation} aria-label="Conversation">
        <header className={styles.topBar}>
          <div className={styles.topStart}>
            <button
              type="button"
              className={styles.iconButton}
              aria-label={open ? 'Hide chats' : 'Show chats'}
              aria-expanded={open}
              aria-controls={listID}
              onClick={toggleList}
            >
              <PanelLeft size={18} strokeWidth={1.55} />
            </button>
          </div>
          <div className={styles.topCenter}>
            {available.length > 0 ? (
              <ModelPicker models={available} value={model} onChange={chooseModel} />
            ) : (
              loading && <ModelsLoading />
            )}
            {model?.reasoning && (
              <EffortPicker
                value={effort}
                efforts={model.reasoning_efforts}
                onChange={chooseEffort}
              />
            )}
          </div>
          <div className={styles.topEnd}>
            <button
              type="button"
              className={styles.iconButton}
              aria-label="Show speed"
              title="Tokens a second"
              aria-pressed={speed}
              onClick={toggleSpeed}
            >
              <Gauge size={17} strokeWidth={1.55} />
            </button>
            {hasMessages && (
              <button
                type="button"
                className={styles.iconButton}
                aria-label="New chat"
                onClick={newChat}
              >
                <SquarePen size={17} strokeWidth={1.55} />
              </button>
            )}
          </div>
        </header>
        <div className={styles.stage}>
          <Hero
            receded={hasMessages}
            tagline={placeTaglines[place] ?? tagline()}
            modelLine={model ? `${modelName(model)} · ${placeLines[place]}` : undefined}
          />
          {conversation && hasMessages && (
            <MessageList
              conversation={conversation}
              live={state.live}
              fresh={state.fresh}
              reduced={reduced}
              names={names}
            />
          )}
        </div>
        <div className={styles.composerArea}>{bottom}</div>
      </section>
    </div>
  );
}
