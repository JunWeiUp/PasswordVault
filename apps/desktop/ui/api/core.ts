// Strongly-typed facade for `vault.command` JSON-RPC calls into `crates/vault-core`.
// Prefer these helpers over raw `call({ op: "..." })` so field names and return types
// stay checked by TypeScript and easy for both humans and AI tools to navigate.
import type { Vault } from "passwordvault/native";
import type { Item } from "./vaultMeta";
import type { CoreRequest, CoreResults } from "./coreContract.generated";

export type { CoreOp, CoreParams, CoreRequest, CoreResults } from "./coreContract.generated";

export type VaultStatus = CoreResults["status"];
export type VaultListResult = { items: Item[]; settings: Record<string, any> };
export type HistoryMeta = { actorType?: string; actor?: string; coalesce?: boolean; summary?: string };
export type SaveResult = { ok?: boolean };
export type AuditEntry = { id: string; weak?: boolean; reused?: boolean; expired?: boolean };
export type AuditResult = { results?: AuditEntry[] } | AuditEntry[];
export type RecoveryStatus = { enabled: boolean };
export type HistoryStatus = CoreResults["history-status"];
export type NoteBodiesStatus = { count: number; split?: boolean };
export type NoteAttachmentsStatus = Partial<CoreResults["note-attachments-status"]>;
export type RelaySummary = {
  enabled?: boolean;
  mode?: string;
  pending?: number;
  peers?: string[] | Record<string, unknown>;
  capabilities?: string[];
  archivedConflicts?: number;
  conflictCount?: number;
  remoteAssetCount?: number;
  skew?: boolean;
};
export type MeshNoteConflictDto = {
  noteId: string;
  title?: string;
  localDevice: string;
  remoteDevice: string;
  revisionId: string;
  capturedAt: number;
  section: string;
  autoMerged: string[];
  assetGuard: string;
  retentionDays: number;
  localItem?: Item;
  remoteItem?: Item;
};

export function createCoreApi(vault: Vault) {
  // Requests are checked against crates/vault-core/contract/commands.json (see tool/core_contract.py).
  const exec = async <T = any>(request: CoreRequest): Promise<T> =>
    JSON.parse(await vault.command(JSON.stringify(request))) as T;

  return {
    raw: exec,
    status: () => exec<VaultStatus>({ op: "status" }),
    create: (password: string) => exec<{ ok?: boolean }>({ op: "create", password }),
    unlock: (password: string) => exec<{ ok?: boolean }>({ op: "unlock", password }),
    lock: () => exec<{ ok?: boolean }>({ op: "lock" }),
    changePassword: (currentPassword: string, newPassword: string) =>
      exec<{ ok?: boolean }>({ op: "change-password", currentPassword, newPassword }),

    list: (summaries = true) => exec<VaultListResult>({ op: "list", summaries }),
    get: (id: string) => exec<Item>({ op: "get", id }),
    save: (item: Item, historyMeta?: HistoryMeta) =>
      exec<SaveResult>(historyMeta ? { op: "save", item, historyMeta } : { op: "save", item }),
    remove: (id: string) => exec<{ ok?: boolean }>({ op: "remove", id }),
    saveSettings: (settings: Record<string, unknown>) =>
      exec<{ ok?: boolean }>({ op: "settings", settings }),

    audit: () => exec<AuditResult>({ op: "audit" }),
    totp: (secret: string, period: number, time: number) =>
      exec<{ code: string }>({ op: "totp", secret, period, time }),
    generate: (options: { length: number; upper: boolean; lower: boolean; digits: boolean; symbols: boolean }) =>
      exec<{ password: string }>({ op: "generate", ...options }),

    categoryAdd: (name: string) => exec<{ ok?: boolean }>({ op: "category-add", name }),
    categoryRename: (name: string, to: string, time: string) =>
      exec<{ updated: number }>({ op: "category-rename", name, to, time }),
    categoryRemove: (name: string, time: string) =>
      exec<{ ok?: boolean }>({ op: "category-remove", name, time }),

    historyStatus: () => exec<HistoryStatus>({ op: "history-status" }),
    historyEnable: () => exec<{ ok?: boolean }>({ op: "history-enable" }),
    historyMilestone: (id: string, summary: string) =>
      exec<{ ok?: boolean }>({ op: "history-milestone", id, summary }),
    /** `R` is the caller's view of a revision (`CoreRevision` in commands.json). */
    historyList: <R = Record<string, any>>(id: string, offset?: number, limit?: number) =>
      exec<{ revisions: R[]; total: number }>({ op: "history-list", id, offset, limit }),
    historyRestore: (id: string, revisionId: string, time = new Date().toISOString()) =>
      exec<{ ok?: boolean }>({ op: "history-restore", id, revisionId, time }),
    historyPrune: (id: string, keepMilestones = false) =>
      exec<{ ok?: boolean }>({ op: "history-prune", id, keepMilestones }),

    recoveryStatus: () => exec<RecoveryStatus>({ op: "recovery-status" }),
    recoveryGenerate: () => exec<{ key: string }>({ op: "recovery-generate" }),
    recoveryEnable: (key: string, currentPassword: string) =>
      exec<{ ok?: boolean }>({ op: "recovery-enable", key, currentPassword }),
    recoveryDisable: (currentPassword: string) =>
      exec<{ ok?: boolean }>({ op: "recovery-disable", currentPassword }),
    recoveryResetPassword: (key: string, newPassword: string) =>
      exec<{ ok?: boolean }>({ op: "recovery-reset-password", key, newPassword }),

    noteBodiesStatus: () => exec<NoteBodiesStatus>({ op: "note-bodies-status" }),
    noteAttachmentsStatus: () => exec<NoteAttachmentsStatus>({ op: "note-attachments-status" }),
    noteAttachmentsList: (noteId: string) =>
      exec<{ attachments?: Record<string, any>[] }>({ op: "note-attachments-list", noteId }),

    devicesStatus: () => exec<{ formatVersion?: number; enabled?: boolean }>({ op: "devices-status" }),
    relayStatus: () => exec<RelaySummary>({ op: "relay-status" }),
    relayMeshConflicts: () => exec<{ conflicts?: MeshNoteConflictDto[] }>({ op: "relay-mesh-conflicts" }),
    relayMeshResolveConflict: (id: string, strategy: "local" | "remote" | "both" | "custom", item?: Item) =>
      exec<{ ok?: boolean; item?: Item; conflictCount?: number }>(
        item ? { op: "relay-mesh-resolve-conflict", id, strategy, item } : { op: "relay-mesh-resolve-conflict", id, strategy },
      ),
  };
}

export type CoreApi = ReturnType<typeof createCoreApi>;
