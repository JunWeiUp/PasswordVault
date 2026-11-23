// Typed wrappers over native modules for methods whose generated ambient d.ts
// lags behind Rust exports (eliminates scattered `(Attachments as any)` casts).
import { Attachments, NoteMarkdown, Relay, type Vault } from "passwordvault/native";

type AttachmentsExt = typeof Attachments & {
  readThumbnail?: (vault: Vault, noteId: string, attachmentId: string) => Promise<string>;
  extractText?: (vault: Vault, noteId: string, attachmentId: string, maxChars: number) => Promise<string>;
  quickLook?: (vault: Vault, noteId: string, attachmentId: string) => Promise<void>;
  listSessions?: (noteId: string) => Promise<string>;
  writeBackSession?: (vault: Vault, sessionId: string) => Promise<string>;
  closeSession?: (sessionId: string) => Promise<void>;
  cleanupSessions?: () => Promise<void>;
  openExternal?: (vault: Vault, noteId: string, attachmentId: string, appName: string | null) => Promise<void>;
  exportPlaintext?: (vault: Vault, noteId: string, attachmentId: string, dest: string) => Promise<void>;
};

type RelayExt = typeof Relay & {
  requestBlob?: (vault: Vault, noteId: string, attachmentId: string, sourceDevice: string | null) => Promise<void>;
};

type NoteMarkdownExt = typeof NoteMarkdown & {
  toReadableMarkdown?: (docJson: string) => string;
  fromMarkdownPreserving?: (md: string, existingDocJson: string) => string;
};

export const attachmentsNative = Attachments as AttachmentsExt;
export const relayNative = Relay as RelayExt;
export const noteMarkdownNative = NoteMarkdown as NoteMarkdownExt;
