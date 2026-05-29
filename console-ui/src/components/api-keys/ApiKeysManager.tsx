"use client";

import { useState } from "react";
import { Info, Key, Loader2, Plus, RefreshCw, ShieldCheck } from "lucide-react";
import type { ApiKey, CreatedKey } from "@/lib/api";
import { CONSOLE_KEY_NOTE, SHARED_BALANCE_NOTE } from "./constants";
import { ConfirmBody } from "./ConfirmBody";
import { KeyCard } from "./KeyCard";
import { KeyForm } from "./KeyForm";
import { Modal } from "./Modal";
import { SecretReveal } from "./SecretReveal";
import { useApiKeys } from "./useApiKeys";

type SecretState = { created: CreatedKey; alreadyConsole: boolean };
type ConfirmState = { kind: "rotate" | "delete"; key: ApiKey };

// ApiKeysManager is the top-level orchestrator: it owns modal/dialog UI state
// and delegates all data + mutations to useApiKeys.
export function ApiKeysManager({ onConsoleKeyChange }: { onConsoleKeyChange?: (key: string) => void }) {
  const {
    authenticated,
    login,
    keys,
    models,
    loading,
    error,
    submitting,
    busyId,
    consoleKeyId,
    reload,
    createKey,
    editKey,
    toggleKey,
    rotateKey,
    deleteKey,
    adoptConsoleKey,
  } = useApiKeys({ onConsoleKeyChange });

  const [createOpen, setCreateOpen] = useState(false);
  const [editing, setEditing] = useState<ApiKey | null>(null);
  const [secret, setSecret] = useState<SecretState | null>(null);
  const [confirm, setConfirm] = useState<ConfirmState | null>(null);

  const confirmBusy = confirm ? busyId === confirm.key.id : false;

  const onCreateSubmit = async (body: Parameters<typeof createKey>[0]) => {
    const created = await createKey(body);
    if (created) {
      setCreateOpen(false);
      setSecret({ created, alreadyConsole: false });
    }
  };

  const onEditSubmit = async (body: Parameters<typeof editKey>[1]) => {
    if (!editing) return;
    if (await editKey(editing.id, body)) setEditing(null);
  };

  const onConfirm = async () => {
    if (!confirm) return;
    if (confirm.kind === "delete") {
      if (await deleteKey(confirm.key)) setConfirm(null);
      return;
    }
    const res = await rotateKey(confirm.key);
    if (res) {
      setConfirm(null);
      setSecret({ created: res.created, alreadyConsole: res.wasConsole });
    }
  };

  let body: React.ReactNode;
  if (!authenticated) {
    body = (
      <div className="rounded-xl bg-bg-secondary shadow-sm p-6 text-center">
        <Key size={20} className="text-text-tertiary mx-auto mb-3" />
        <p className="text-sm text-text-secondary mb-4">Sign in to create and manage your API keys.</p>
        <button
          onClick={login}
          className="inline-flex items-center gap-2 px-5 py-2.5 rounded-lg bg-coral text-white text-sm font-medium hover:opacity-90 transition-all"
        >
          Sign In
        </button>
      </div>
    );
  } else if (loading) {
    body = (
      <div className="flex items-center justify-center py-12">
        <Loader2 size={20} className="animate-spin text-accent-brand" />
      </div>
    );
  } else if (error) {
    body = (
      <div className="rounded-xl bg-bg-secondary shadow-sm p-6 text-center">
        <p className="text-sm text-accent-red mb-3">{error}</p>
        <button
          onClick={() => void reload()}
          className="inline-flex items-center gap-2 px-4 py-2 rounded-lg border border-border-dim text-text-secondary text-sm font-medium hover:bg-bg-hover transition-colors"
        >
          <RefreshCw size={14} />
          Retry
        </button>
      </div>
    );
  } else if (keys.length === 0) {
    body = (
      <div className="rounded-xl bg-bg-secondary shadow-sm p-8 text-center">
        <Key size={22} className="text-text-tertiary mx-auto mb-3" />
        <p className="text-sm text-text-primary font-medium mb-1">No API keys yet</p>
        <p className="text-sm text-text-tertiary mb-4">Create a named key to start using the Darkbloom API.</p>
        <button
          onClick={() => setCreateOpen(true)}
          className="inline-flex items-center gap-2 px-4 py-2 rounded-lg bg-coral text-white text-sm font-medium hover:opacity-90 transition-all"
        >
          <Plus size={15} />
          Create your first key
        </button>
      </div>
    );
  } else {
    body = (
      <div className="space-y-3">
        {keys.map((k) => (
          <KeyCard
            key={k.id}
            keyData={k}
            isConsole={consoleKeyId === k.id}
            busy={busyId === k.id}
            onToggle={() => void toggleKey(k)}
            onEdit={() => setEditing(k)}
            onRotate={() => setConfirm({ kind: "rotate", key: k })}
            onDelete={() => setConfirm({ kind: "delete", key: k })}
          />
        ))}
      </div>
    );
  }

  return (
    <section>
      <div className="flex items-center justify-between mb-4 gap-3">
        <h2 className="text-lg font-semibold text-text-primary">API Keys</h2>
        {authenticated && (
          <button
            onClick={() => setCreateOpen(true)}
            className="flex items-center gap-2 px-4 py-2 rounded-lg bg-coral text-white text-sm font-medium hover:opacity-90 transition-all"
          >
            <Plus size={15} />
            New key
          </button>
        )}
      </div>

      <div className="rounded-xl bg-accent-brand/5 border border-accent-brand/15 px-4 py-3 mb-4 space-y-2">
        <div className="flex items-start gap-2.5">
          <Info size={15} className="text-accent-brand shrink-0 mt-0.5" />
          <p className="text-xs text-text-secondary leading-relaxed">{SHARED_BALANCE_NOTE}</p>
        </div>
        <div className="flex items-start gap-2.5">
          <ShieldCheck size={15} className="text-accent-brand shrink-0 mt-0.5" />
          <p className="text-xs text-text-secondary leading-relaxed">{CONSOLE_KEY_NOTE}</p>
        </div>
      </div>

      {body}

      <Modal open={createOpen} onClose={() => !submitting && setCreateOpen(false)} title="Create API key">
        <KeyForm
          mode="create"
          models={models}
          submitting={submitting}
          onCancel={() => setCreateOpen(false)}
          onSubmit={onCreateSubmit}
        />
      </Modal>

      <Modal open={!!editing} onClose={() => !submitting && setEditing(null)} title="Edit API key">
        {editing && (
          <KeyForm
            key={editing.id}
            mode="edit"
            initial={editing}
            models={models}
            submitting={submitting}
            onCancel={() => setEditing(null)}
            onSubmit={onEditSubmit}
          />
        )}
      </Modal>

      <Modal open={!!secret} onClose={() => setSecret(null)} title="Save your API key">
        {secret && (
          <SecretReveal
            created={secret.created}
            alreadyConsole={secret.alreadyConsole}
            onSetConsole={() => adoptConsoleKey(secret.created)}
            onClose={() => setSecret(null)}
          />
        )}
      </Modal>

      <Modal
        open={!!confirm}
        onClose={() => !confirmBusy && setConfirm(null)}
        title={confirm?.kind === "delete" ? "Revoke API key" : "Rotate API key"}
      >
        {confirm && (
          <ConfirmBody
            message={
              confirm.kind === "delete"
                ? `Revoke "${confirm.key.name || "this key"}"? Any application using it will stop working immediately. This cannot be undone.`
                : `Rotate "${confirm.key.name || "this key"}"? The current secret is revoked immediately and a new one is issued. Update anything using the old secret.`
            }
            confirmLabel={confirm.kind === "delete" ? "Revoke key" : "Rotate key"}
            danger={confirm.kind === "delete"}
            busy={confirmBusy}
            onCancel={() => setConfirm(null)}
            onConfirm={onConfirm}
          />
        )}
      </Modal>
    </section>
  );
}
