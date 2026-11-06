/** Correlate asynchronous iframe snapshots; stale replies can never resolve a newer save. */
export class RichSnapshotGate<T> {
  private sequence = 0;
  private work = 0;
  private closed = false;
  private pending?: {
    id: string;
    resolve: (value: T) => void;
    reject: (reason: Error) => void;
    timer: ReturnType<typeof setTimeout>;
  };
  constructor(private readonly timeout = 3000) {}
  private reject(reason: string) {
    const pending = this.pending;
    if (!pending) return;
    this.pending = undefined;
    clearTimeout(pending.timer);
    pending.reject(Error(reason));
  }
  hold(): () => void {
    this.work++;
    this.reject("Editor is busy");
    let released = false;
    return () => {
      if (!released) {
        released = true;
        this.work--;
      }
    };
  }
  request(send: (id: string) => void): Promise<T> {
    if (this.closed || this.work || this.pending)
      return Promise.reject(Error("Editor is busy"));
    return new Promise((resolve, reject) => {
      const id = String(++this.sequence);
      this.pending = {
        id,
        resolve,
        reject,
        timer: setTimeout(
          () => this.reject("Editor snapshot unavailable"),
          this.timeout,
        ),
      };
      try {
        send(id);
      } catch {
        this.reject("Editor snapshot unavailable");
      }
    });
  }
  accept(id: unknown, value: () => T): boolean {
    const pending = this.pending;
    if (!pending || id !== pending.id) return false;
    this.pending = undefined;
    clearTimeout(pending.timer);
    try {
      pending.resolve(value());
    } catch (error) {
      pending.reject(
        error instanceof Error ? error : Error("Invalid snapshot"),
      );
    }
    return true;
  }
  close() {
    this.closed = true;
    this.reject("Editor closed");
  }
}

export function mergeRichSource<T extends Record<string, any>>(
  item: T,
  source: unknown,
  originalSource?: string,
): T {
  if (typeof source !== "string" || source.length > 16 * 1024 * 1024)
    throw Error("Invalid editor data");
  if (item.noteFormat !== "rich-v1" && source === originalSource) return item;
  const value = JSON.parse(source);
  if (
    value.format !== "rich-v1" ||
    value.document?.type !== "doc" ||
    !Array.isArray(value.document.content) ||
    typeof value.text !== "string"
  )
    throw Error("Invalid editor data");
  return {
    ...item,
    ...(item.noteFormat !== "rich-v1" && !item.noteOriginal
      ? {
          noteOriginal: {
            format: item.noteFormat ?? "markdown",
            source: item.note ?? "",
          },
        }
      : {}),
    noteFormat: "rich-v1",
    noteDocument: value.document,
    note: value.text,
  };
}
